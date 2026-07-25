;;; relay-prefetch-ui.el --- Dired UI for relay prefetch -*- lexical-binding: t; -*-

;;; Code:

(require 'dired)
(require 'seq)
(require 'relay-prefetch)
(require 'relay-content-prefetch)

;;;; Prefetch folder UI (built-in Dired, not a second filesystem browser)

(require 'dired)

(defface relay-prefetch-content-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face used for content-prefetch markers in `relay-prefetch-dired-mode'."
  :group 'relay)

(defvar-local relay--prefetch-dired-overlays nil)
(defvar relay-prefetch-dired-mode nil)

(defun relay--prefetch-dired-clear-decorations ()
  (mapc #'delete-overlay relay--prefetch-dired-overlays)
  (setq relay--prefetch-dired-overlays nil))

(defun relay--prefetch-dired-decorate ()
  "Show a content-prefetch marker next to matching directories in this Dired."
  (when (and (derived-mode-p 'dired-mode) relay-prefetch-dired-mode)
    (relay--prefetch-dired-clear-decorations)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((filename (ignore-errors (dired-get-filename nil))))
          (when-let* ((parsed (and filename (relay--parse filename)))
                      (authority (car parsed))
                      (localdir (directory-file-name (cdr parsed))))
            (when (relay--content-prefetch-marked-p authority localdir)
              (let ((overlay (make-overlay (line-beginning-position)
                                            (line-beginning-position))))
                (overlay-put overlay 'before-string
                             (propertize "● " 'face 'relay-prefetch-content-face))
                (push overlay relay--prefetch-dired-overlays))))
        (forward-line 1))))))

(defun relay--prefetch-dired-target-directories ()
  "Return selected directories in the current Dired buffer.

No marks means the current line, as in ordinary Dired commands."
  (let ((targets (seq-filter #'file-directory-p (dired-get-marked-files nil nil))))
    (unless targets
      (user-error "relay: mark or point at at least one directory"))
    (dolist (dir targets)
      (unless (relay--parse dir)
        (user-error "relay: not an /relay: directory: %s" dir)))
    targets))

(defun relay-prefetch-dired-toggle-content ()
  "Toggle content-prefetch marks for selected Dired directories."
  (interactive)
  (dolist (dir (relay--prefetch-dired-target-directories))
    (let* ((parsed (relay--parse dir))
           (key (cons (car parsed) (directory-file-name (cdr parsed)))))
      (if (relay--content-prefetch-marked-p (car key) (cdr key))
          (relay-unmark-content-prefetch dir)
        (relay-mark-content-prefetch dir))))
  (relay--prefetch-dired-decorate))

(defun relay-prefetch-dired-switch-profile (name)
  "Make NAME the sole active prefetch profile and redraw this Dired buffer."
  (interactive (list (completing-read "Switch to profile: "
                                      (relay--prefetch-profile-names) nil t)))
  (relay-prefetch-switch-profile name)
  (relay--prefetch-dired-decorate)
  (force-mode-line-update))

(defun relay-prefetch-dired-create-profile (name)
  "Create NAME for this Dired root and make it the active profile."
  (interactive (list (read-string "New prefetch profile: ")))
  (relay-prefetch-create-profile name dired-directory)
  (relay-prefetch-dired-switch-profile name))

(defun relay-prefetch-dired-rename-profile (name new-name)
  "Rename a profile from this Dired buffer and refresh its status display."
  (interactive
   (list (completing-read "Rename profile: " (relay--prefetch-profile-names) nil t)
         (read-string "New profile name: ")))
  (relay-prefetch-rename-profile name new-name)
  (relay--prefetch-dired-decorate)
  (force-mode-line-update))

(defun relay-prefetch-dired-delete-profile (name)
  "Delete a profile from this Dired buffer and refresh its status display."
  (interactive (list (completing-read "Delete profile: "
                                      (relay--prefetch-profile-names) nil t)))
  (relay-prefetch-delete-profile name)
  (relay--prefetch-dired-decorate)
  (force-mode-line-update))

(defun relay-prefetch-dired-show-problems ()
  "Display unavailable folders in the selected prefetch profile."
  (interactive)
  (let ((problems (relay-prefetch-profile-problems)))
    (if (null problems)
        (message "relay: no unavailable folders in profile %s"
                 relay--prefetch-selected-profile)
      (with-output-to-temp-buffer "*relay Prefetch Problems*"
        (princ (format "Profile %s — unavailable folders:\n\n"
                       relay--prefetch-selected-profile))
        (dolist (problem problems)
          (princ (format "%s\n  %s\n\n"
                         (relay--wrap (caar problem) (cdar problem))
                         (cdr problem))))))))

(defun relay-prefetch-dired-retry-problems ()
  "Retry unavailable folders, then redraw the profile status."
  (interactive)
  (relay-prefetch-retry-profile-problems)
  (force-mode-line-update))

(defvar relay-prefetch-dired-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-p") #'relay-prefetch-dired-toggle-content)
    (define-key map (kbd "C-c C-s") #'relay-prefetch-dired-switch-profile)
    (define-key map (kbd "C-c C-n") #'relay-prefetch-dired-create-profile)
    (define-key map (kbd "C-c C-r") #'relay-prefetch-dired-rename-profile)
    (define-key map (kbd "C-c C-k") #'relay-prefetch-dired-delete-profile)
    (define-key map (kbd "C-c C-e") #'relay-prefetch-dired-show-problems)
    (define-key map (kbd "C-c C-t") #'relay-prefetch-dired-retry-problems)
    map)
  "Keymap for `relay-prefetch-dired-mode'.")

(define-minor-mode relay-prefetch-dired-mode
  "Dired UI for content-prefetch folder profiles.

`C-c C-p' toggles content prefetch for the current or Dired-marked folders;
`C-c C-s' switches profiles; `C-c C-n' creates one rooted here; `C-c C-r'
renames one; `C-c C-k' deletes one; `C-c C-e' shows unavailable configured
folders; `C-c C-t' retries them.  The ordinary Dired commands remain
responsible for browsing and refreshing."
  :lighter " EPrefetch"
  :keymap relay-prefetch-dired-mode-map
  (unless (derived-mode-p 'dired-mode)
    (setq relay-prefetch-dired-mode nil)
    (user-error "relay-prefetch-dired-mode requires a Dired buffer"))
  (if relay-prefetch-dired-mode
      (progn
        (add-hook 'dired-after-readin-hook #'relay--prefetch-dired-decorate nil t)
        (setq-local header-line-format
                    '(:eval (let ((count (length (relay-prefetch-profile-problems))))
                              (format "relay content prefetch — profile: %s%s"
                                      relay--prefetch-selected-profile
                                      (if (zerop count) ""
                                        (format " — unavailable: %d" count))))))
        (relay--prefetch-dired-decorate))
    (remove-hook 'dired-after-readin-hook #'relay--prefetch-dired-decorate t)
    (relay--prefetch-dired-clear-decorations)
    (kill-local-variable 'header-line-format)))

;;;###autoload
(defun relay-prefetch-dired (dir)
  "Open DIR in Dired with content-prefetch profile controls enabled."
  (interactive (list (read-directory-name "Prefetch Dired directory: ")))
  (unless (relay--parse (expand-file-name dir))
    (user-error "relay: not an /relay: directory: %s" dir))
  (let ((buffer (dired-noselect dir)))
    (pop-to-buffer buffer)
    (relay-prefetch-dired-mode 1)))


(provide 'relay-prefetch-ui)
;;; relay-prefetch-ui.el ends here

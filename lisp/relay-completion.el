;;; relay-completion.el --- Minibuffer completion for relay -*- lexical-binding: t; -*-

;;; Code:

(require 'relay-core)

;;;; ---------------------------------------------------------------------------
;;;; Minibuffer completion

(defvar relay--ssh-host-cache :uninitialized
  "Cached SSH host aliases for minibuffer completion.

The cache avoids rereading SSH configuration on every keystroke.  Call
`relay-clear-ssh-host-cache' after editing it in a running Emacs.")

(defun relay-clear-ssh-host-cache ()
  "Forget cached SSH completion candidates.
The next completion reads `~/.ssh/config' and `~/.ssh/known_hosts' again."
  (interactive)
  (setq relay--ssh-host-cache :uninitialized))

(defun relay--ssh-hosts-from-config (file)
  "Return literal `Host' aliases declared in SSH config FILE.
Patterns and negated entries are deliberately excluded: they are valid SSH
configuration, but not useful destinations to offer in a file minibuffer."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (hosts)
        (dolist (line (split-string (buffer-string) "\n"))
          (setq line (or (car (split-string line "#" t)) ""))
          (when (string-match "\\`[ \\t]*[Hh][Oo][Ss][Tt][ \\t]+\\(.+\\)\\'" line)
            (dolist (host (split-string (match-string 1 line) "[ \\t]+" t))
              (unless (or (string-match-p "[*!?]" host)
                          (string-prefix-p "!" host))
                (push host hosts)))))
        hosts))))

(defun relay--ssh-hosts-from-known-hosts (file)
  "Return literal host names found in OpenSSH known-hosts FILE."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (hosts)
        (dolist (line (split-string (buffer-string) "\n"))
          ;; Hashed entries cannot be turned back into usable host names.  A
          ;; marker such as @cert-authority precedes, rather than replaces,
          ;; the host field.
          (when (and (not (string-match-p "\\`[ \\t]*\\(?:#\\|\\'\\)" line))
                     (string-match "\\`\\(?:@[^ \\t]+[ \\t]+\\)?\\([^ \\t]+\\)" line))
            (dolist (host (split-string (match-string 1 line) "," t))
              (cond
               ((string-match "\\`\\[\\([^]]+\\)\\]:[0-9]+\\'" host)
                (push (match-string 1 host) hosts))
               ((and (not (string-prefix-p "|" host))
                     (not (string-match-p "[*!?]" host)))
                (push host hosts))))))
        hosts))))

(defun relay--ssh-user-file (name)
  "Return local SSH file NAME without relying on tilde expansion.

Some long-lived Emacs sessions can have a filename handler/advice that leaves
`~/.ssh/...' literal.  OpenSSH itself uses HOME for these per-user files, so
prefer that explicit directory and use tilde expansion only as a fallback."
  (let ((home (getenv "HOME")))
    (if (and (stringp home) (not (string-empty-p home)))
        (concat (file-name-as-directory home) ".ssh/" name)
      (expand-file-name (concat "~/.ssh/" name)))))

(defun relay--ssh-hosts ()
  "Return cached, completion-safe SSH destinations from local SSH files."
  ;; Development versions used nil for a cached empty result.  That makes a
  ;; transient failed read permanent across package reloads: nil is then
  ;; indistinguishable from poisoned legacy state and no code retries.  Treat
  ;; legacy nil as uninitialized and reserve :empty for a valid empty scan.
  (when (memq relay--ssh-host-cache '(:uninitialized nil))
    (let* ((default-directory "/")
           (hosts
            (sort (delete-dups
                   (append (relay--ssh-hosts-from-config
                            (relay--ssh-user-file "config"))
                           (relay--ssh-hosts-from-known-hosts
                            (relay--ssh-user-file "known_hosts"))))
                  #'string-lessp)))
      (setq relay--ssh-host-cache (or hosts :empty))))
  (unless (eq relay--ssh-host-cache :empty)
    relay--ssh-host-cache))

(defun relay--partial-completion-candidates (fullname)
  "Return absolute relay candidates for partial magic name FULLNAME.
Return nil when FULLNAME is not one of the incomplete prefixes this package
owns.  This function performs no network I/O."
  (cond
   ((equal fullname "/") '("/relay:"))
   ;; Treat relay like every other root entry: `/e TAB' should retain it
   ;; alongside local matches such as `/etc/', not require the entire name.
   ((and (string-match "\\`/\\([^/]*\\)\\'" fullname)
         (string-prefix-p (match-string 1 fullname) "relay"))
   '("/relay:"))
   ((string-match-p "\\`/relay:\\'" fullname)
    '("/relay:local:/" "/relay:ssh+"))
   ((string-match "\\`/relay:ssh\\+\\([^:/]*\\)\\'" fullname)
    (let ((partial (match-string 1 fullname)))
      ;; The slash makes a selected host an immediately usable remote root,
      ;; rather than another incomplete magic-name prefix.
      (mapcar (lambda (host) (format "/relay:ssh+%s:/" host))
              (sort (seq-filter (lambda (host) (string-prefix-p partial host))
                                (relay--ssh-hosts))
                    #'string-lessp))))))

(defun relay--completion-fullname (file directory)
  "Combine FILE and DIRECTORY without redispatching file-name handlers."
  (cond
   ((string-prefix-p "/" file) file)
   ;; Emacs can split an unfinished prefix as DIRECTORY=/relay:ssh+
   ;; and FILE="".  It is not a directory yet, so preserve it literally.
   ((string-prefix-p "/relay:" directory)
    (concat directory file))
   (t (concat (file-name-as-directory directory) file))))

(defun relay--completion-directory-prefix (directory)
  "Return the literal prefix removed from a partial completion candidate."
  (if (string-prefix-p "/relay:" directory)
      directory
    (file-name-as-directory directory)))

(defun relay--minibuffer-completion-candidates (file directory)
  "Return relative relay candidates for FILE in DIRECTORY, or nil.
This deliberately accepts only strings.  Some minibuffer internals call
file-name primitives with sentinel values while setting themselves up; those
calls must be left entirely to Emacs."
  (when (and minibuffer-completing-file-name
             (stringp file) (stringp directory))
    (when-let ((absolute (relay--partial-completion-candidates
                          (relay--completion-fullname file directory))))
      (let ((prefix (relay--completion-directory-prefix directory)))
        (mapcar (lambda (candidate)
                  (if (string-prefix-p prefix candidate)
                      (substring candidate (length prefix))
                    candidate))
                absolute)))))

(defun relay--advice-file-name-all-completions (original file directory)
  "Add relay's partial magic names during file-minibuffer completion."
  (if-let ((candidates (relay--minibuffer-completion-candidates file directory)))
      ;; At the local root keep ordinary matching entries as well.  Once the
      ;; user has begun a relay name, only our syntactically valid
      ;; continuations are relevant and, importantly, no incomplete name
      ;; reaches the normal file-name handler.
      (if (let ((fullname (relay--completion-fullname file directory)))
            (and (equal directory "/")
                 (not (string-prefix-p "/relay:" fullname))))
          ;; A few third-party file completion providers return method symbols
          ;; among their root candidates.  `file-name-all-completions' is
          ;; specified to return strings; filtering here both enforces that
          ;; contract and prevents a frontend from later signalling
          ;; "wrong-type-argument stringp relay" while it narrows /.
          (delete-dups (append candidates
                               (seq-filter #'stringp
                                           (funcall original file directory))))
        candidates)
    (funcall original file directory)))

(defun relay--advice-file-name-completion (original file directory &optional predicate)
  "Complete an incomplete relay magic name without a global file handler."
  (if-let ((candidates (relay--minibuffer-completion-candidates file directory)))
      (let* ((fullname (relay--completion-fullname file directory))
             (at-root (and (equal directory "/")
                           (not (string-prefix-p "/relay:" fullname))))
             ;; At / the table must agree with `file-name-all-completions':
             ;; keeping ordinary root candidates prevents TAB from eagerly
             ;; inserting `relay:' as though it were the only choice.
             (all-candidates
              (cond
               ;; `ssh+' is the normal interactive transport.  Returning it
               ;; here avoids a non-visible common-prefix result for the two
               ;; choices (`local:/' and `ssh+') in completion frontends.
               ((equal fullname "/relay:")
                (seq-filter (lambda (candidate)
                              (string-suffix-p "ssh+" candidate))
                            candidates))
               (at-root
                (delete-dups (append candidates
                                     (seq-filter #'stringp
                                                 (funcall #'file-name-all-completions
                                                          file directory)))))
               (t candidates)))
             (completion-predicate
              ;; Partial relay segments (ssh+ and host names) do not name
              ;; files, so `file-exists-p' is inapplicable until the final
              ;; authority/path form.  At the local root we still use it for
              ;; ordinary filesystem entries.
              (when (and predicate at-root)
                (lambda (entry)
                  (let ((candidate (car entry)))
                    ;; A partial magic name does not exist yet, so it cannot
                    ;; be tested with `file-exists-p'.  Real root candidates
                    ;; still honor the caller's predicate.
                    (or (string-prefix-p "relay:" candidate)
                        (funcall predicate
                                 (expand-file-name candidate directory))))))))
        (when (and (string-match-p "\\`/relay:ssh\\+\\'" fullname)
                   (> (length all-candidates) 1))
          (message "relay SSH targets: %s (type a prefix to narrow)"
                   (mapconcat #'identity all-candidates ", ")))
        (try-completion file (mapcar #'list all-candidates) completion-predicate))
    (funcall original file directory predicate)))

(defun relay--advice-completion-all-completions
    (original string collection predicate point &optional metadata)
  "Keep ssh-host candidates intact in the real file-minibuffer UI.

Emacs's `read-file-name-internal' has already split an unfinished authority by
the time it is asked for all candidates.  At this higher layer STRING is still
the literal minibuffer input, so return the authority candidates directly.
The dotted final cdr is the completion boundary required by this API."
  (let ((candidates (and (stringp string)
                         (memq collection '(read-file-name-internal
                                            completion-file-name-table))
                         (string-prefix-p "/relay:" string)
                         (relay--partial-completion-candidates string))))
    (if candidates
        (let* ((base (if (string-prefix-p "/relay:ssh+" string)
                         (length "/relay:ssh+")
                       (length "/relay:")))
               ;; File completion results contain only the component that
               ;; replaces text after their dotted-list boundary.  Returning
               ;; full magic names with BASE after `ssh+' made a selected host
               ;; duplicate the prefix in the minibuffer.
               (relative (mapcar (lambda (candidate)
                                   (substring candidate base))
                                 candidates)))
          (append relative base))
      ;; Emacs 30 passes METADATA on some completion paths.  Keep it optional
      ;; for older Emacsen, but forward it when present: omitting it here made
      ;; every remote completion fail with "wrong number of arguments".
      (if metadata
          (funcall original string collection predicate point metadata)
        (funcall original string collection predicate point)))))

(provide 'relay-completion)
;;; relay-completion.el ends here

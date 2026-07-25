;;; benchmark-profiles.el --- Profile switch benchmark -*- lexical-binding: t; -*-

;; Run in a fresh batch Emacs from the repository root:
;;   Emacs --batch -Q -l test/benchmark-profiles.el --eval \
;;     '(relay-benchmark-profile-switch "your-host" "/tmp/fixture")'

(require 'cl-lib)

(defconst relay-benchmark-profiles--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(load-file (expand-file-name "lisp/relay.el" relay-benchmark-profiles--root))

(defun relay-benchmark-profiles--dirs (base profile)
  (mapcar (lambda (n) (format "%s/%s/dir-%d" base profile n))
          (number-sequence 0 9)))

(defun relay-benchmark-profiles--wait (conn dirs)
  (let ((deadline (+ (float-time) 30.0)))
    (while (and (not (cl-every (lambda (dir)
                                 (gethash dir (relay-conn-dircache conn)))
                               dirs))
                (< (float-time) deadline))
      (accept-process-output (relay-conn-process conn) 0.1))
    (unless (cl-every (lambda (dir) (gethash dir (relay-conn-dircache conn))) dirs)
      (error "Timed out waiting for profile directories to warm"))))

(defun relay-benchmark-profile-switch (host base)
  "Measure profile-switch return and full-warm time for HOST under BASE.

BASE must contain `alpha/dir-00' through `dir-09' and the same layout under
`beta'.  The benchmark alternates profiles three times in one persistent SSH
connection; each switch evicts the prior profile's client cache."
  (let* ((authority (format "ssh+%s" host))
         (alpha (relay-benchmark-profiles--dirs base "alpha"))
         (beta (relay-benchmark-profiles--dirs base "beta"))
         (config (make-temp-file "relay-profile-benchmark-"))
         (relay-prefetch-config-file config)
         (relay--connections (make-hash-table :test 'equal))
         (conn nil))
    (unwind-protect
        (progn
          (relay--prefetch-config-load)
          (setq conn (relay--connection authority))
          (relay--prefetch-profile-put
           "alpha" (list :name "alpha" :listing (mapcar (lambda (d) (cons authority d)) alpha)
                         :content nil))
          (relay--prefetch-profile-put
           "beta" (list :name "beta" :listing (mapcar (lambda (d) (cons authority d)) beta)
                        :content nil))
          (relay-prefetch-switch-profile "alpha")
          (relay-benchmark-profiles--wait conn alpha)
          (dolist (target '("beta" "alpha" "beta"))
            (let* ((dirs (if (equal target "alpha") alpha beta))
                   (start (float-time)))
              (relay-prefetch-switch-profile target)
              (let ((returned (- (float-time) start)))
                (relay-benchmark-profiles--wait conn dirs)
                (princ (format "relay switch=%s return=%.3fs warm=%.3fs dirs=%d\n"
                               target returned (- (float-time) start) (length dirs)))))))
      (when (and conn (process-live-p (relay-conn-process conn)))
        (delete-process (relay-conn-process conn)))
      (when (file-exists-p config) (delete-file config)))))

(defun relay-benchmark-tramp-directories (host base)
  "Measure TRAMP's serial cold listing of the ten directories under BASE/beta."
  (require 'tramp)
  (let ((start (float-time)))
    (dolist (dir (relay-benchmark-profiles--dirs base "beta"))
      (directory-files (format "/ssh:%s:%s/" host dir) nil nil t))
    (princ (format "tramp serial-open=%.3fs dirs=10\n" (- (float-time) start)))))

;;; benchmark-profiles.el ends here

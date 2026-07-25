;;; benchmark-completion.el --- Small remote completion benchmark -*- lexical-binding: t; -*-

;; Run from the repository root, for example:
;;   Emacs --batch -Q -l test/benchmark-completion.el \
;;     --eval '(relay-benchmark-completion "relay" "your-host" "/tmp/dir/")'

(require 'cl-lib)
(require 'tramp)

(defconst relay-benchmark--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(load-file (expand-file-name "lisp/relay.el" relay-benchmark--root))

(defun relay-benchmark--hash-values (table)
  (let (values)
    (maphash (lambda (_ value) (push value values)) table)
    values))

(defun relay-benchmark--seconds (thunk)
  (let ((start (float-time))
        (value (funcall thunk)))
    (cons (- (float-time) start) value)))

(defun relay-benchmark-completion (backend host directory)
  "Print cold/warm completion timings for BACKEND on HOST and DIRECTORY.

BACKEND is either `relay' or `tramp'.  The cold measurement includes
connection setup and the first listing.  The two warm calls reuse the same
Emacs process and distinguish an empty-prefix query from narrowing a prefix."
  (let* ((dir (pcase backend
                ("relay" (format "/relay:ssh+%s:%s" host directory))
                ("tramp" (format "/ssh:%s:%s" host directory))
                (_ (error "Unknown backend: %s" backend))))
         (cold (relay-benchmark--seconds
                (lambda () (file-name-all-completions "" dir))))
         (warm (relay-benchmark--seconds
                (lambda () (file-name-all-completions "" dir))))
         (narrow (relay-benchmark--seconds
                  (lambda () (file-name-all-completions "item-09" dir)))))
    (princ (format "%s cold=%.3fs warm=%.3fs narrow=%.3fs candidates=%d narrow-candidates=%d\n"
                   backend (car cold) (car warm) (car narrow)
                   (length (cdr cold)) (length (cdr narrow))))
    (dolist (conn (relay-benchmark--hash-values relay--connections))
      (when (process-live-p (relay-conn-process conn))
        (delete-process (relay-conn-process conn))))))

;;; benchmark-completion.el ends here

;;; relay-save-tests.el --- Async Relay save specifications -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst relay-save-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
(load-file (expand-file-name "lisp/relay.el" relay-save-test--root))

(defvar relay-conflict--request-async-function nil)
(defvar relay-conflict--fetch-async-function nil)

(defun relay-save-test--bytes (text)
  (encode-coding-string text 'utf-8))

(defun relay-save-test--revision (tag)
  (list :schema 1 :state "present" :kind "file" :dev 9
        :ino (pcase tag ('base 10) ('one 11) ('two 12) (_ 13))
        :size 4 :mtime_sec 1700000000
        :mtime_nsec (pcase tag ('base 1) ('one 2) ('two 3) (_ 4))
        :ctime_sec 1700000000 :ctime_nsec 5 :mode #o644
        :sha256 (format "%064x" (sxhash tag))))

(defmacro relay-save-test--with-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name "/relay:local:/tmp/relay-save-fixture.txt")
     (insert "base\n")
     (set-buffer-modified-p nil)
     (relay-conflict--install-buffer
      (relay-save-test--bytes "base\n") (relay-save-test--revision 'base) 'utf-8)
     (let ((require-final-newline nil))
       ,@body)))

(defun relay-save-test--edit (text)
  (erase-buffer)
  (insert text))

(ert-deftest relay-save-command-returns-with-request-pending-and-marker-set ()
  "The interactive command stops after hooks and capture, before its reply."
  (relay-save-test--with-buffer
    (let (callback captured (before 0) (after 0))
      (add-hook 'before-save-hook (lambda () (setq before (1+ before))) nil t)
      (add-hook 'after-save-hook (lambda () (setq after (1+ after))) nil t)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (setq captured args callback done))))
        (should (relay-save-buffer-async)))
      (should (= before 1))
      (should (= after 0))
      (should callback)
      (should (equal (plist-get captured :bytes)
                     (relay-save-test--bytes "local\n")))
      (should (buffer-modified-p))
      (should (eq relay-save--status 'saving))
      (funcall callback (list :ok t :revision (relay-save-test--revision 'one)))
      (should-not (buffer-modified-p))
      (should (= after 1))
      (should (eq relay-save--status 'saved)))))

(ert-deftest relay-save-interactive-command-clears-stale-saving-message ()
  "Async progress must not leave Emacs's old `Saving file ...' text visible."
  (relay-save-test--with-buffer
    (relay-save-test--edit "local\n")
    (let ((relay-conflict--request-async-function
           (lambda (_op _args _identity _done) nil))
          (echo-area "Saving file /relay:local:/tmp/relay-save-fixture.txt...")
          cleared)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (if format-string
                       (setq echo-area (apply #'format format-string args))
                     (setq echo-area nil cleared t)))))
        (call-interactively #'relay-save-buffer-async))
      (should cleared)
      (should-not echo-area))))

(ert-deftest relay-save-final-newline-and-before-hook-precede-capture ()
  "Final-newline work and `before-save-hook' both affect captured bytes."
  (relay-save-test--with-buffer
    (let (captured)
      (relay-save-test--edit "local")
      (add-hook 'before-save-hook (lambda () (goto-char (point-max)) (insert "hook")) nil t)
      (let ((require-final-newline t)
            (relay-conflict--request-async-function
             (lambda (_op args _identity _done) (setq captured args))))
        (relay-save-buffer-async))
      (should (equal (plist-get captured :bytes)
                     (relay-save-test--bytes "local\nhook"))))))

(ert-deftest relay-save-new-file-uses-missing-state-precondition ()
  (relay-save-test--with-buffer
    (setq relay-conflict--base
          (list :bytes "" :revision (list :schema 1 :state "missing")
                :coding 'utf-8))
    (relay-save-test--edit "created\n")
    (let (captured)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity _done) (setq captured args))))
        (relay-save-buffer-async))
      (should (equal (plist-get captured :expected_revision)
                     (list :schema 1 :state "missing"))))))

(ert-deftest relay-save-edits-during-flight-remain-modified-and-skip-after-hook ()
  (relay-save-test--with-buffer
    (let (callback (after 0))
      (add-hook 'after-save-hook (lambda () (setq after (1+ after))) nil t)
      (relay-save-test--edit "first\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq callback done))))
        (relay-save-buffer-async)
        (goto-char (point-max))
        (insert "newer\n")
        (funcall callback (list :ok t :revision (relay-save-test--revision 'one))))
      (should (buffer-modified-p))
      (should (= after 0))
      (should (eq relay-save--status 'saved-newer))
      (should (equal (plist-get relay-conflict--base :bytes)
                     (relay-save-test--bytes "first\n"))))))

(ert-deftest relay-save-success-waits-for-origin-buffer-selection-before-timing ()
  (let ((origin (generate-new-buffer " *relay delayed success*"))
        (other (generate-new-buffer " *relay other*")) callback)
    (unwind-protect
        (progn
          (switch-to-buffer origin)
          (setq buffer-file-name "/relay:local:/tmp/delayed.txt")
          (insert "base\n")
          (setq-local relay-conflict--base
                      (list :bytes (relay-save-test--bytes "base\n")
                            :revision (relay-save-test--revision 'base) :coding 'utf-8))
          (relay-async-save-mode 1)
          (relay-save-test--edit "local\n")
          (let ((require-final-newline nil)
                (relay-conflict--request-async-function
                 (lambda (_op _args _identity done) (setq callback done))))
            (relay-save-buffer-async))
          (switch-to-buffer other)
          (funcall callback (list :ok t :revision (relay-save-test--revision 'one)))
          (with-current-buffer origin
            (should (eq relay-save--status 'saved))
            (should-not relay-save--success-timer))
          (switch-to-buffer origin)
          (relay-save--post-command)
          (should (timerp relay-save--success-timer)))
      (dolist (buffer (list origin other))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (relay-save--cancel-success-timer)
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest relay-save-killed-origin-reports-terminal-result ()
  (let ((buffer (generate-new-buffer " *relay killed save*")) callback reported)
    (with-current-buffer buffer
      (setq buffer-file-name "/relay:local:/tmp/killed.txt")
      (insert "local\n")
      (setq-local relay-conflict--base
                  (list :bytes (relay-save-test--bytes "base\n")
                        :revision (relay-save-test--revision 'base) :coding 'utf-8))
      (relay-async-save-mode 1)
      (let ((require-final-newline nil)
            (relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq callback done))))
        (relay-save-buffer-async))
      (set-buffer-modified-p nil))
    (kill-buffer buffer)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq reported (apply #'format format-string args)))))
      (funcall callback (list :ok t :revision (relay-save-test--revision 'one))))
    (should (string-match-p "originating buffer was killed" reported))))

(ert-deftest relay-save-rename-during-flight-never-cleans-new-identity ()
  (relay-save-test--with-buffer
    (let ((old-base relay-conflict--base) callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq callback done))))
        (relay-save-buffer-async)
        (setq buffer-file-name "/relay:local:/tmp/renamed.txt")
        (funcall callback (list :ok t :revision (relay-save-test--revision 'one))))
      (should (buffer-modified-p))
      (should (equal relay-conflict--base old-base))
      (should (eq relay-save--status 'saved-newer)))))

(ert-deftest relay-save-coalesces-identical-and-keeps-only-latest-snapshot ()
  (relay-save-test--with-buffer
    (let (requests)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (setq requests (append requests (list (cons args done)))))))
        (relay-save-test--edit "one\n")
        (relay-save-buffer-async)
        (relay-save-buffer-async)
        (should (= (length requests) 1))
        (relay-save-test--edit "two\n")
        (relay-save-buffer-async)
        (relay-save-test--edit "three\n")
        (relay-save-buffer-async)
        (should (= (length requests) 1))
        (funcall (cdar requests)
                 (list :ok t :revision (relay-save-test--revision 'one)))
        (should (= (length requests) 2))
        (let ((second (cadr requests)))
          (should (equal (plist-get (car second) :bytes)
                         (relay-save-test--bytes "three\n")))
          (should (equal (plist-get (car second) :expected_revision)
                         (relay-save-test--revision 'one)))
          (funcall (cdr second)
                   (list :ok t :revision (relay-save-test--revision 'two)))))
      (should-not (buffer-modified-p))
      (should (equal (plist-get relay-conflict--base :revision)
                     (relay-save-test--revision 'two))))))

(ert-deftest relay-save-never-dispatches-queued-snapshot-after-conflict ()
  (relay-save-test--with-buffer
    (let (requests fetch-callback)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (push (cons args done) requests)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-test--edit "one\n")
        (relay-save-buffer-async)
        (relay-save-test--edit "two\n")
        (relay-save-buffer-async)
        (funcall (cdar requests)
                 (list :ok nil :error_code "conflict"
                       :conflict (list :kind "changed")))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "remote\n")
                       :revision (relay-save-test--revision 'one))))
      (should (= (length requests) 1))
      (should-not relay-save--queued)
      (should (eq relay-save--status 'conflict))
      (should (buffer-modified-p)))))

(ert-deftest relay-save-never-dispatches-queued-snapshot-after-definite-failure ()
  (relay-save-test--with-buffer
    (let (requests)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (push (cons args done) requests))))
        (relay-save-test--edit "one\n")
        (relay-save-buffer-async)
        (relay-save-test--edit "two\n")
        (relay-save-buffer-async)
        (funcall (cdar requests) '(:ok nil :error "permission denied")))
      (should (= (length requests) 1))
      (should-not relay-save--queued)
      (should (eq relay-save--status 'failed))
      (should (string-match-p "retry" (relay-save--header-banner))))))

(ert-deftest relay-save-request-equal-to-active-cancels-an-older-queued-snapshot ()
  (relay-save-test--with-buffer
    (let (requests)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (push (cons args done) requests))))
        (relay-save-test--edit "one\n")
        (relay-save-buffer-async)
        (relay-save-test--edit "two\n")
        (relay-save-buffer-async)
        (relay-save-test--edit "one\n")
        (relay-save-buffer-async)
        (should-not relay-save--queued)
        (funcall (cdar requests)
                 (list :ok t :revision (relay-save-test--revision 'one))))
      (should (= (length requests) 1))
      (should-not (buffer-modified-p)))))

(ert-deftest relay-save-structured-conflict-kinds-become-actionable ()
  (dolist (kind '("changed" "appeared" "type_changed" "deleted"))
    (relay-save-test--with-buffer
      (let (write-callback fetch-callback)
        (relay-save-test--edit "local\n")
        (let ((relay-conflict--request-async-function
               (lambda (_op _args _identity done) (setq write-callback done)))
              (relay-conflict--fetch-async-function
               (lambda (_identity done) (setq fetch-callback done))))
          (relay-save-buffer-async)
          (funcall write-callback
                   (list :ok nil :error_code "conflict"
                         :conflict (list :kind kind)))
          (if (equal kind "deleted")
              (funcall fetch-callback '(:ok nil :error "missing"))
            (funcall fetch-callback
                     (list :ok t :bytes (relay-save-test--bytes "remote\n")
                           :revision (relay-save-test--revision 'one)))))
        (should (eq relay-save--status 'conflict))
        (should (equal (plist-get relay-conflict--state :reason) kind))
        (should (string-match-p "C-x C-s" (relay-save--header-banner)))))))

(ert-deftest relay-save-convergent-conflict-adopts-remote-revision ()
  (relay-save-test--with-buffer
    (let (write-callback fetch-callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-buffer-async)
        (funcall write-callback
                 '(:ok nil :error_code "conflict" :conflict (:kind "changed")))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "local\n")
                       :revision (relay-save-test--revision 'one))))
      (should-not (buffer-modified-p))
      (should (eq relay-save--status 'saved))
      (should (equal (plist-get relay-conflict--base :revision)
                     (relay-save-test--revision 'one))))))

(ert-deftest relay-save-lost-reply-reconciles-without-blind-write-retry ()
  (relay-save-test--with-buffer
    (let (requests fetch-callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done) (push (cons args done) requests)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-buffer-async)
        (funcall (cdar requests) '(:ok nil :transport t :error "lost"))
        (should (= (length requests) 1))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "base\n")
                       :revision (relay-save-test--revision 'one)))
        (should (= (length requests) 1))
        (should (eq relay-save--status 'unknown))
        (should (eq (plist-get relay-conflict--state :status) 'retry))
        (relay-save-buffer-async)
        (should (= (length requests) 2))
        (should (equal (plist-get (caar requests) :expected_revision)
                       (relay-save-test--revision 'one)))))))

(ert-deftest relay-save-lost-reply-read-failure-stays-unknown ()
  (relay-save-test--with-buffer
    (let (write-callback fetch-callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-buffer-async)
        (funcall write-callback '(:ok nil :transport t :error "lost"))
        (funcall fetch-callback '(:ok nil :transport t :error "offline")))
      (should (eq relay-save--status 'unknown))
      (should (buffer-modified-p))
      (should (string-match-p "inspect" (relay-save--header-banner))))))

(ert-deftest relay-save-lost-reply-remote-equals-local-confirms-success ()
  (relay-save-test--with-buffer
    (let (write-callback fetch-callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-buffer-async)
        (funcall write-callback '(:ok nil :transport t :error "lost"))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "local\n")
                       :revision (relay-save-test--revision 'one))))
      (should-not (buffer-modified-p))
      (should (eq relay-save--status 'saved)))))

(ert-deftest relay-save-lost-reply-third-version-becomes-conflict ()
  (relay-save-test--with-buffer
    (let (write-callback fetch-callback)
      (relay-save-test--edit "local\n")
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done)))
            (relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done))))
        (relay-save-buffer-async)
        (funcall write-callback '(:ok nil :transport t :error "lost"))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "third\n")
                       :revision (relay-save-test--revision 'one))))
      (should (eq relay-save--status 'conflict))
      (should (equal (plist-get relay-conflict--state :reason) "changed")))))

(ert-deftest relay-save-keep-local-resolution-is-asynchronous ()
  (relay-save-test--with-buffer
    (let* ((snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           callback captured)
      (relay-save-test--edit "local\n")
      (setq relay-conflict--state snapshot relay-save--status 'conflict)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (setq captured args callback done))))
        (relay-save--dispatch
         (relay-save--resolution-operation snapshot 'keep-local)))
      (should (eq relay-save--status 'saving))
      (should (equal (plist-get captured :expected_revision)
                     (relay-save-test--revision 'one)))
      (funcall callback (list :ok t :revision (relay-save-test--revision 'two)))
      (should-not relay-conflict--state)
      (should-not (buffer-modified-p)))))

(ert-deftest relay-save-restore-base-waits-for-confirmation-before-replacing-live ()
  (relay-save-test--with-buffer
    (let* ((snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           callback)
      (relay-save-test--edit "local\n")
      (setq relay-conflict--state snapshot relay-save--status 'conflict)
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (let ((relay-conflict--request-async-function
               (lambda (_op _args _identity done) (setq callback done))))
          (relay-save--dispatch
           (relay-save--resolution-operation snapshot 'restore-base))))
      (should (equal (buffer-string) "local\n"))
      (funcall callback (list :ok t :revision (relay-save-test--revision 'two)))
      (should (equal (buffer-string) "base\n"))
      (should-not (buffer-modified-p)))))

(ert-deftest relay-save-save-as-is-async-and-retains-original-conflict ()
  (relay-save-test--with-buffer
    (let* ((snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           callback captured)
      (relay-save-test--edit "local\n")
      (setq relay-conflict--state snapshot relay-save--status 'conflict)
      (let ((relay-conflict--request-async-function
             (lambda (_op args _identity done)
               (setq captured args callback done))))
        (relay-save--dispatch
         (relay-save--resolution-operation
          snapshot 'save-as "/relay:local:/tmp/copy.txt")))
      (should (equal (plist-get captured :expected_revision)
                     (list :schema 1 :state "missing")))
      (funcall callback (list :ok t :revision (relay-save-test--revision 'two)))
      (should (equal relay-conflict--state snapshot))
      (should (buffer-modified-p))
      (should (eq relay-save--status 'conflict)))))

(ert-deftest relay-save-save-as-lost-reply-inspects-the-new-target ()
  (relay-save-test--with-buffer
    (let* ((snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           write-callback fetch-callback fetched-identity)
      (relay-save-test--edit "local\n")
      (setq relay-conflict--state snapshot relay-save--status 'conflict)
      (let ((relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done)))
            (relay-conflict--fetch-async-function
             (lambda (identity done)
               (setq fetched-identity identity fetch-callback done))))
        (relay-save--dispatch
         (relay-save--resolution-operation
          snapshot 'save-as "/relay:local:/tmp/copy.txt"))
        (funcall write-callback '(:ok nil :transport t :error "lost"))
        (should (equal (plist-get fetched-identity :path) "/tmp/copy.txt"))
        (funcall fetch-callback
                 (list :ok t :bytes (relay-save-test--bytes "local\n")
                       :revision (relay-save-test--revision 'two))))
      (should (eq relay-save--status 'conflict))
      (should (equal relay-conflict--state snapshot)))))

(ert-deftest relay-save-restore-base-second-conflict-retains-original-and-recovery ()
  (relay-save-test--with-buffer
    (let* ((snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           write-callback fetch-callback operation)
      (relay-save-test--edit "local\n")
      (setq relay-conflict--state snapshot relay-save--status 'conflict)
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (let ((relay-conflict--request-async-function
               (lambda (_op _args _identity done) (setq write-callback done)))
              (relay-conflict--fetch-async-function
               (lambda (_identity done) (setq fetch-callback done))))
          (setq operation (relay-save--resolution-operation snapshot 'restore-base))
          (relay-save--dispatch operation)
          (funcall write-callback
                   '(:ok nil :error_code "conflict" :conflict (:kind "changed")))
          (funcall fetch-callback
                   (list :ok t :bytes (relay-save-test--bytes "remote two\n")
                         :revision (relay-save-test--revision 'two)))))
      (should (equal (plist-get relay-conflict--state :local)
                     (relay-save-test--bytes "local\n")))
      (should (eq (plist-get relay-conflict--state :local-recovery)
                  (plist-get operation :local-recovery)))
      (should (buffer-live-p (plist-get relay-conflict--state :local-recovery)))
      (should (eq relay-save--status 'conflict)))))

(ert-deftest relay-save-merge-publication-is-async-and-closes-only-on-success ()
  (relay-save-test--with-buffer
    (relay-save-test--edit "local\n")
    (let* ((live (current-buffer))
           (snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           (merge (generate-new-buffer " *relay async merge*"))
           fetch-callback write-callback (closed 0))
      (let ((relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done)))
            (relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done))))
        (unwind-protect
            (progn
            (setq relay-conflict--state snapshot)
            (with-current-buffer merge
              (insert "merged\n")
              (setq-local relay-conflict--merge-snapshot snapshot)
              (setq-local relay-conflict--merge-live-buffer live)
              (setq-local relay-conflict--ediff-quit-function
                          (lambda () (setq closed (1+ closed))))
              (relay-conflict-merge-mode 1)
              (relay-save-apply-merge-async))
            (should (= closed 0))
            (should-not write-callback)
            (funcall fetch-callback
                     (list :ok t :bytes (relay-save-test--bytes "remote\n")
                           :revision (relay-save-test--revision 'one)))
            (should write-callback)
            (should (= closed 0))
            (should (equal (buffer-string) "local\n"))
            (funcall write-callback
                     (list :ok t :revision (relay-save-test--revision 'two)))
            (should (= closed 1))
            (should (equal (buffer-string) "merged\n"))
            (should-not (buffer-modified-p)))
          (when (buffer-live-p merge)
            (with-current-buffer merge (set-buffer-modified-p nil))
            (kill-buffer merge)))))))

(ert-deftest relay-save-merge-second-conflict-preserves-ediff-and-recovery ()
  (relay-save-test--with-buffer
    (relay-save-test--edit "local\n")
    (let* ((live (current-buffer))
           (snapshot (list :reason "changed" :base relay-conflict--base
                           :local (relay-save-test--bytes "local\n")
                           :remote (list :bytes (relay-save-test--bytes "remote\n")
                                         :revision (relay-save-test--revision 'one))))
           (merge (generate-new-buffer " *relay conflicting merge*"))
           fetch-callback write-callback (closed 0))
      (let ((relay-conflict--fetch-async-function
             (lambda (_identity done) (setq fetch-callback done)))
            (relay-conflict--request-async-function
             (lambda (_op _args _identity done) (setq write-callback done))))
        (unwind-protect
            (cl-letf (((symbol-function 'display-buffer) #'ignore))
              (setq relay-conflict--state snapshot)
              (with-current-buffer merge
                (insert "merged\n")
                (setq-local relay-conflict--merge-snapshot snapshot)
                (setq-local relay-conflict--merge-live-buffer live)
                (setq-local relay-conflict--ediff-quit-function
                            (lambda () (setq closed (1+ closed))))
                (relay-conflict-merge-mode 1)
                (relay-save-apply-merge-async))
              (funcall fetch-callback
                       (list :ok t :bytes (relay-save-test--bytes "remote\n")
                             :revision (relay-save-test--revision 'one)))
              (funcall write-callback
                       '(:ok nil :error_code "conflict"
                         :conflict (:kind "changed")))
              (funcall fetch-callback
                       (list :ok t :bytes (relay-save-test--bytes "remote two\n")
                             :revision (relay-save-test--revision 'two)))
              (should (= closed 0))
              (should (buffer-live-p merge))
              (should (eq relay-save--status 'conflict))
              (should (buffer-live-p
                       (plist-get relay-conflict--state :merge-recovery))))
          (when (buffer-live-p merge)
            (with-current-buffer merge (set-buffer-modified-p nil))
            (kill-buffer merge)))))))

(ert-deftest relay-save-synchronous-fallback-never-uses-async-backend ()
  "Direct programmatic visited writes retain `write-contents-functions'."
  (relay-save-test--with-buffer
    (relay-save-test--edit "local\n")
    (let ((relay-conflict--request-async-function
           (lambda (&rest _) (ert-fail "programmatic save became async")))
          (relay-conflict--request-function
           (lambda (_op _args)
             (list :ok t :revision (relay-save-test--revision 'one)))))
      (cl-letf (((symbol-function 'message) #'ignore))
        (should (relay-conflict--write-contents))))
    (should-not (buffer-modified-p))))

(ert-deftest relay-save-real-local-server-write-returns-before-reply ()
  "Exercise the async command through real framing and server revision logic."
  (let* ((binary (expand-file-name "server/target/debug/relay-server"
                                    relay-save-test--root))
         (relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path binary)
         (local (make-temp-file "relay-async-save-" nil ".txt" "base\n"))
         (remote (format "/relay:local:%s" local)) buffer)
    (unwind-protect
        (progn
          (unless (file-executable-p binary)
            (ert-skip (format "local Relay server is not built: %s" binary)))
          (setq buffer (find-file-noselect remote))
          (with-current-buffer buffer
            (relay-save-test--edit "async\n")
            (let ((started (float-time)) (require-final-newline nil))
              (relay-save-buffer-async)
              (should (< (- (float-time) started) 0.1)))
            (should relay-save--active)
            (should (buffer-modified-p))
            (let ((deadline (+ (float-time) 3.0)))
              (while (and relay-save--active (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not relay-save--active)
            (should-not (buffer-modified-p))
            (should (eq relay-save--status 'saved)))
          (with-temp-buffer
            (insert-file-contents-literally local)
            (should (equal (buffer-string) "async\n"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (relay-save--cancel-success-timer)
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (maphash (lambda (_authority connection)
                 (let ((process (relay-conn-process connection)))
                   (when (process-live-p process) (delete-process process))))
               relay--connections)
      (when (file-exists-p local) (delete-file local)))))

(ert-deftest relay-save-install-remaps-only-the-buffer-local-interactive-command ()
  (relay-save-test--with-buffer
    (should relay-async-save-mode)
    (should (eq (command-remapping 'save-buffer) #'relay-save-buffer-async))
    (should (memq #'relay-conflict--write-contents write-contents-functions))))

(provide 'relay-save-tests)
;;; relay-save-tests.el ends here

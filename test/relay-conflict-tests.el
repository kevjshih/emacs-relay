;;; relay-conflict-tests.el --- Red specifications for conflict-safe saves -*- lexical-binding: t; -*-

;; These tests deliberately name the small internal API which the forthcoming
;; `relay-conflict.el' owns.  It is intentionally not required here: until
;; that module exists, `relay-conflict-test--call' turns an absent entry point
;; into an ERT assertion failure rather than a load-time or void-function error.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst relay-conflict-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(load-file (expand-file-name "lisp/relay.el" relay-conflict-test--root))

;; Declarations only: the production module owns their defaults and behavior.
;; Declaring them here makes the backend hooks dynamically bindable in these
;; red tests and keeps byte compilation quiet before that module exists.
(defvar-local relay-conflict--base nil)
(defvar relay-conflict--request-function nil)
(defvar relay-conflict--fetch-function nil)

(defun relay-conflict-test--call (function &rest arguments)
  "Call planned conflict FUNCTION, failing clearly while it is unimplemented."
  (if (fboundp function)
      (apply function arguments)
    (ert-fail (format "Missing planned conflict API: %S" function))))

(defun relay-conflict-test--bytes (string)
  "Return STRING as raw, unibyte UTF-8 fixture bytes."
  (encode-coding-string string 'utf-8))

(defun relay-conflict-test--revision (tag &optional state kind)
  "Return a deliberately complete, distinct revision fixture for TAG."
  (list :schema 1 :state (or state "present") :kind (or kind "file")
        :dev 101 :ino (pcase tag
                         ('base 11) ('remote 12) ('replacement 13) (_ 14))
        :size (length (symbol-name tag))
        :mtime_sec 1700000000 :mtime_nsec (pcase tag ('base 1) ('remote 2) (_ 3))
        :ctime_sec 1700000000 :ctime_nsec (pcase tag ('base 4) ('remote 5) (_ 6))
        :mode #o644 :sha256 (format "%064x" (sxhash tag))))

(defconst relay-conflict-test--base (relay-conflict-test--bytes "base\n"))
(defconst relay-conflict-test--local (relay-conflict-test--bytes "local\n"))
(defconst relay-conflict-test--remote (relay-conflict-test--bytes "remote\n"))

(defmacro relay-conflict-test--with-buffer (&rest body)
  "Evaluate BODY in a visited relay-shaped buffer with tiny fixtures."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name "/relay:local:/tmp/relay-conflict-fixture.txt")
     (insert (decode-coding-string relay-conflict-test--base 'utf-8))
     (set-buffer-modified-p nil)
     ,@body))

;; Planned state API:
;; - `relay-conflict--base' is buffer-local and holds (:bytes :revision :coding).
;; - `relay-conflict--record-base' records only known, successful snapshots.
;; - `relay-conflict--save', `--revert', and `--auto-revert' return plists
;;   with :status, never advance BASE on :conflict or :uncertain, and use the
;;   dynamically-bound backend hooks below for deterministic test transport.
;; - `relay-conflict--classify' compares encoded raw bytes, not dirty flags.
;; - `relay-conflict--write-arguments' receives BYTES REVISION PURPOSE
;;   APPEND MUST-BE-NEW.  PURPOSE is `visited' or `unvisited'; only a visited,
;;   non-append, non-`must-be-new' whole-file save gains `:expected_revision'.
;; - `relay-conflict--resolve' accepts a conflict snapshot and one of
;;   `keep-local', `keep-remote', `restore-base', `save-as', `cancel', `merge'.

(ert-deftest relay-conflict-visit-records-a-byte-accurate-base ()
  "A successful visit establishes raw bytes, revision, and coding as BASE."
  (relay-conflict-test--with-buffer
    (let ((revision (relay-conflict-test--revision 'base)))
      (should (equal (relay-conflict-test--call
                      'relay-conflict--record-base
                      relay-conflict-test--base revision 'utf-8)
                     (list :bytes relay-conflict-test--base :revision revision :coding 'utf-8)))
      (should (equal relay-conflict--base
                     (list :bytes relay-conflict-test--base :revision revision :coding 'utf-8))))))

(ert-deftest relay-conflict-clean-revert-advances-base ()
  "A clean fresh revert replaces content and advances BASE exactly once."
  (relay-conflict-test--with-buffer
    (let* ((old (relay-conflict-test--revision 'base))
           (new (relay-conflict-test--revision 'remote))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision old :coding 'utf-8))
           (result (relay-conflict-test--call 'relay-conflict--revert
                                                (list :bytes relay-conflict-test--remote :revision new))))
      (should (eq (plist-get result :status) 'reverted))
      (should (equal (buffer-string) "remote\n"))
      (should (equal (plist-get relay-conflict--base :revision) new)))))

(ert-deftest relay-conflict-successful-save-advances-base ()
  "Only a successful conditional write may establish the returned revision."
  (relay-conflict-test--with-buffer
    (let* ((old (relay-conflict-test--revision 'base))
           (new (relay-conflict-test--revision 'remote))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision old :coding 'utf-8))
           (relay-conflict--request-function
            (lambda (op args)
              (should (equal op "write"))
              (should (equal (plist-get args :expected_revision) old))
              (list :ok t :revision new)))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (result (relay-conflict-test--call 'relay-conflict--save)))
      (should (eq (plist-get result :status) 'saved))
      (should (equal (plist-get relay-conflict--base :bytes) relay-conflict-test--local))
      (should (equal (plist-get relay-conflict--base :revision) new)))))

(ert-deftest relay-conflict-visited-save-replaces-in-progress-message-on-success ()
  "A custom visited save must visibly replace Emacs's `Saving file ...' text."
  (relay-conflict-test--with-buffer
    (let ((relay-conflict--base
           (list :bytes relay-conflict-test--base
                 :revision (relay-conflict-test--revision 'base)
                 :coding 'utf-8))
          completion)
      (cl-letf (((symbol-function 'relay-conflict--save)
                 (lambda () (list :status 'saved)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq completion (apply #'format format-string args)))))
        (should (relay-conflict--write-contents)))
      (should (equal completion
                     "Wrote /relay:local:/tmp/relay-conflict-fixture.txt")))))

(ert-deftest relay-conflict-resolution-reports-adopted-remote-completion ()
  "Resolving a save by adopting REMOTE reports that terminal outcome clearly."
  (relay-conflict-test--with-buffer
    (let ((relay-conflict--base
           (list :bytes relay-conflict-test--base
                 :revision (relay-conflict-test--revision 'base)
                 :coding 'utf-8))
          (noninteractive nil)
          completion)
      (cl-letf (((symbol-function 'relay-conflict--save)
                 (lambda () (list :status 'conflict :conflict 'snapshot)))
                ((symbol-function 'relay-conflict--interactive-menu)
                 (lambda (_snapshot) (list :status 'adopted-remote)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq completion (apply #'format format-string args)))))
        (should (relay-conflict--write-contents)))
      (should (equal completion
                     (concat "Adopted remote contents of "
                             "/relay:local:/tmp/relay-conflict-fixture.txt"))))))

(ert-deftest relay-conflict-failed-save-never-advances-base ()
  "A structured conflict retains both the prior BASE and modified LOCAL."
  (relay-conflict-test--with-buffer
    (let* ((base-revision (relay-conflict-test--revision 'base))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision base-revision :coding 'utf-8))
           (relay-conflict--request-function
            (lambda (_op _args) (list :ok nil :error_code "conflict" :conflict (list :kind "changed"))))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (result (relay-conflict-test--call 'relay-conflict--save)))
      (should (eq (plist-get result :status) 'conflict))
      (should (equal relay-conflict--base
                     (list :bytes relay-conflict-test--base :revision base-revision :coding 'utf-8)))
      (should (buffer-modified-p)))))

(ert-deftest relay-conflict-uncertain-save-never-advances-base ()
  "A transport loss is uncertain, never treated as a successful save."
  (relay-conflict-test--with-buffer
    (let* ((base-revision (relay-conflict-test--revision 'base))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision base-revision :coding 'utf-8))
           (relay-conflict--request-function (lambda (&rest _) (error "transport closed")))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (result (relay-conflict-test--call 'relay-conflict--save)))
      (should (eq (plist-get result :status) 'uncertain))
      (should (equal (plist-get relay-conflict--base :revision) base-revision))
      (should (eq (plist-get relay-conflict--state :status) 'uncertain))
      (should (equal (plist-get relay-conflict--state :local) relay-conflict-test--local))
      (should (buffer-modified-p)))))

(ert-deftest relay-conflict-transport-retry-persists-base-local-and-remote ()
  "Remote==BASE after a lost reply is an explicit retry, retained in state."
  (relay-conflict-test--with-buffer
    (let* ((revision (relay-conflict-test--revision 'base))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision revision :coding 'utf-8))
           (relay-conflict--request-function (lambda (&rest _) (error "lost transport")))
           (relay-conflict--fetch-function
            (lambda () (list :bytes relay-conflict-test--base :revision revision)))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (result (relay-conflict-test--call 'relay-conflict--save)))
      (should (eq (plist-get result :status) 'retry))
      (should (eq (plist-get relay-conflict--state :status) 'retry))
      (should (equal (plist-get relay-conflict--state :base) relay-conflict--base))
      (should (equal (plist-get relay-conflict--state :local) relay-conflict-test--local)))))

(ert-deftest relay-conflict-transport-retry-requires-an-explicit-second-save ()
  "The ambiguity read is never a write; a later save uses its REMOTE revision."
  (relay-conflict-test--with-buffer
    (let* ((base-revision (relay-conflict-test--revision 'base))
           (retry-revision (relay-conflict-test--revision 'replacement))
           (saved-revision (relay-conflict-test--revision 'remote))
           (relay-conflict--base
            (list :bytes relay-conflict-test--base
                  :revision base-revision :coding 'utf-8))
           (writes 0)
           seen-expected
           (relay-conflict--request-function
            (lambda (_op args)
              (setq writes (1+ writes))
              (setq seen-expected (plist-get args :expected_revision))
              (if (= writes 1)
                  (error "lost transport")
                (list :ok t :revision saved-revision))))
           (relay-conflict--fetch-function
            (lambda () (list :bytes relay-conflict-test--base
                             :revision retry-revision))))
      (erase-buffer) (insert "local\n")
      (should (eq (plist-get (relay-conflict--save) :status) 'retry))
      (should (= writes 1))
      (should (equal seen-expected base-revision))
      (should (eq (plist-get (relay-conflict--save) :status) 'saved))
      (should (= writes 2))
      (should (equal seen-expected retry-revision))
      (should (equal (plist-get relay-conflict--base :revision) saved-revision)))))

(ert-deftest relay-conflict-visited-save-sends-expected-revision ()
  "Normal visited whole-file saves carry the exact BASE revision."
  (let ((revision (relay-conflict-test--revision 'base)))
    (should (equal (relay-conflict-test--call
                    'relay-conflict--write-arguments
                    relay-conflict-test--local revision 'visited nil nil)
                   (list :bytes relay-conflict-test--local :expected_revision revision)))))

(ert-deftest relay-conflict-append-create-and-unrelated-writes-keep-legacy-paths ()
  "Append, create-only, and unvisited writes must not acquire automatic merges."
  (dolist (case '((append visited t nil :append t)
                  (create-only visited nil t :must_be_new t)
                  (unvisited unvisited nil nil :legacy t)))
    (pcase-let ((`(,_name ,purpose ,append ,must-be-new ,key ,value) case))
      (let ((arguments (relay-conflict-test--call
                        'relay-conflict--write-arguments
                        relay-conflict-test--local (relay-conflict-test--revision 'base)
                        purpose append must-be-new)))
        (should (equal (plist-get arguments key) value))
        (should-not (plist-member arguments :expected_revision))))))

(ert-deftest relay-conflict-new-file-save-expects-missing-state ()
  "A first save of a nonexistent visited path is a create-only conditional write."
  (should (equal (relay-conflict-test--call
                  'relay-conflict--write-arguments relay-conflict-test--local
                  (list :schema 1 :state "missing") 'visited nil nil)
                 (list :bytes relay-conflict-test--local
                       :expected_revision (list :schema 1 :state "missing")))))

(ert-deftest relay-conflict-classifies-remote-only-change-by-encoded-bytes ()
  "Clean LOCAL plus changed REMOTE is remote-only even when dirty flag lies."
  (should (eq (relay-conflict-test--call 'relay-conflict--classify
                                           relay-conflict-test--base
                                           relay-conflict-test--base
                                           relay-conflict-test--remote)
              'remote-only)))

(ert-deftest relay-conflict-undo-to-base-is-not-a-divergent-edit ()
  "Edit then undo exactly to BASE is compared as bytes, not `buffer-modified-p'."
  (should (eq (relay-conflict-test--call 'relay-conflict--classify
                                           relay-conflict-test--base
                                           relay-conflict-test--base
                                           relay-conflict-test--base)
              'unchanged)))

(ert-deftest relay-conflict-convergent-local-and-remote-adopts-revision ()
  "Equal LOCAL and REMOTE avoid Ediff and adopt REMOTE's returned revision."
  (let ((revision (relay-conflict-test--revision 'remote)))
    (should (equal (relay-conflict-test--call
                    'relay-conflict--classify relay-conflict-test--base
                    relay-conflict-test--local relay-conflict-test--local revision)
                   (list :kind 'convergent :revision revision :action 'adopt-remote)))))

(ert-deftest relay-conflict-classifies-all-server-conflict-kinds ()
  "Changed, deleted, appeared, and replacement retain distinct menu states."
  (dolist (kind '("changed" "deleted" "appeared" "type_changed"))
    (let ((menu (relay-conflict-test--call 'relay-conflict--menu-state
                                             (list :kind kind))))
      (should (eq (plist-get menu :kind) (intern kind)))
      (should (member 'save-as (plist-get menu :choices)))))
  (let ((type-menu (relay-conflict-test--call 'relay-conflict--menu-state
                                                (list :kind "type_changed"))))
    (should (equal (plist-get type-menu :choices) '(save-as cancel)))))

(defun relay-conflict-test--snapshot ()
  "Return one complete conflict snapshot accepted by `--resolve'."
  (list :base (list :bytes relay-conflict-test--base :revision (relay-conflict-test--revision 'base) :coding 'utf-8)
        :local relay-conflict-test--local
        :remote (list :bytes relay-conflict-test--remote :revision (relay-conflict-test--revision 'remote))))

(ert-deftest relay-conflict-keep-local-writes-against-fetched-remote ()
  "Keep Local must conditionally replace the exact REMOTE snapshot, never force-write."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (seen nil)
         (relay-conflict--request-function
          (lambda (_op args) (setq seen args) (list :ok t :revision (relay-conflict-test--revision 'replacement)))))
    (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--resolve snapshot 'keep-local)
                           :status) 'saved))
    (should (equal (plist-get seen :expected_revision)
                   (plist-get (plist-get snapshot :remote) :revision)))
    (should (equal (plist-get seen :bytes) relay-conflict-test--local))))

(ert-deftest relay-conflict-keep-remote-creates-visible-local-recovery ()
  "Keep Remote preserves LOCAL, installs REMOTE, and makes the visit clean."
  (relay-conflict-test--with-buffer
    (let* ((snapshot (relay-conflict-test--snapshot))
           (result (relay-conflict-test--call 'relay-conflict--resolve snapshot 'keep-remote)))
      (should (eq (plist-get result :status) 'adopted-remote))
      (should (buffer-live-p (plist-get result :local-recovery)))
      (should (equal (with-current-buffer (plist-get result :local-recovery) (buffer-string)) "local\n"))
      (should (equal (buffer-string) "remote\n"))
      (should-not (buffer-modified-p)))))

(ert-deftest relay-conflict-restore-base-preserves-both-discarded-versions ()
  "Restore Base stores LOCAL and REMOTE recovery buffers before conditional write."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (seen nil)
         (relay-conflict--request-function
          (lambda (_op args) (setq seen args) (list :ok t :revision (relay-conflict-test--revision 'replacement))))
         (result (relay-conflict-test--call 'relay-conflict--resolve snapshot 'restore-base)))
    (should (eq (plist-get result :status) 'saved))
    (should (buffer-live-p (plist-get result :local-recovery)))
    (should (buffer-live-p (plist-get result :remote-recovery)))
    (should (equal (plist-get seen :bytes) relay-conflict-test--base))
    (should (equal (plist-get seen :expected_revision)
                   (plist-get (plist-get snapshot :remote) :revision)))))

(ert-deftest relay-conflict-save-as-is-create-only-and-leaves-conflict ()
  "Save Local As creates only a new path, preserving the original conflict."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (seen nil)
         (relay-conflict--state nil)
         (relay-conflict--request-function
          (lambda (_op args) (setq seen args) (list :ok t :revision (relay-conflict-test--revision 'replacement))))
         (result (relay-conflict-test--call 'relay-conflict--resolve snapshot 'save-as "/new.txt")))
    (should (eq (plist-get result :status) 'saved-as))
    (should (equal (plist-get seen :expected_revision) (list :schema 1 :state "missing")))
    (should (equal (plist-get result :conflict) snapshot))
    (should (equal relay-conflict--state snapshot))))

(ert-deftest relay-conflict-unsupported-remote-allows-only-save-as-or-cancel ()
  "Unsafe final types and encodings never expose overwrite or merge choices."
  (dolist (code '("unsupported_file_type" "unsupported_encoding" "file_too_large"))
    (relay-conflict-test--with-buffer
      (erase-buffer) (insert "local\n")
      (let* ((base (list :bytes relay-conflict-test--base
                         :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
             (relay-conflict--base base)
             (relay-conflict--request-function
              (lambda (&rest _) (list :ok nil :error_code code :error "unsupported")))
             (relay-conflict--fetch-function (lambda () (error "not safely readable")))
             (result (relay-conflict--save))
             (conflict (plist-get result :conflict))
             (menu (relay-conflict--menu-state
                    (list :kind (plist-get conflict :reason)))))
        (should (eq (plist-get result :status) 'conflict))
        (should (equal (plist-get conflict :reason) "type_changed"))
        (should (equal (plist-get menu :choices) '(save-as cancel)))))))

(ert-deftest relay-conflict-cancel-retains-live-local-and-conflict ()
  "Cancel is non-destructive and retains the captured conflict for a later choice."
  (relay-conflict-test--with-buffer
    (erase-buffer) (insert "local\n")
    (let* ((snapshot (relay-conflict-test--snapshot))
           (result (relay-conflict-test--call 'relay-conflict--resolve snapshot 'cancel)))
      (should (eq (plist-get result :status) 'cancelled))
      (should (equal (buffer-string) "local\n"))
      (should (equal (plist-get result :conflict) snapshot))
      (should (buffer-modified-p)))))

(ert-deftest relay-conflict-second-conflict-refreshes-without-losing-original-local ()
  "A resolution race refreshes REMOTE and reopens the menu with original LOCAL."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (new-revision (relay-conflict-test--revision 'replacement))
         (relay-conflict--request-function
          (lambda (&rest _) (list :ok nil :error_code "conflict"
                                  :conflict (list :kind "changed" :current_revision new-revision))))
         (relay-conflict--fetch-function
          (lambda () (list :bytes (relay-conflict-test--bytes "remote two\n") :revision new-revision)))
         (result (relay-conflict-test--call 'relay-conflict--resolve snapshot 'keep-local)))
    (should (eq (plist-get result :status) 'conflict))
    (should (equal (plist-get (plist-get result :conflict) :local) relay-conflict-test--local))
    (should (equal (plist-get (plist-get (plist-get result :conflict) :remote) :revision) new-revision))))

(ert-deftest relay-conflict-menu-loops-after-second-conflict ()
  "Interactive resolution refreshes and reopens the same menu after a race."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (new-revision (relay-conflict-test--revision 'replacement))
         (keys '(?l ?q))
         (relay-conflict--request-function
          (lambda (&rest _) (list :ok nil :error_code "conflict"
                                  :conflict (list :kind "changed" :current_revision new-revision))))
         (relay-conflict--fetch-function
          (lambda () (list :bytes (relay-conflict-test--bytes "remote two\n") :revision new-revision))))
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) (pop keys))))
      (let ((result (relay-conflict-test--call 'relay-conflict--interactive-menu snapshot)))
        (should (eq (plist-get result :status) 'cancelled))
        (should (equal (plist-get (plist-get result :conflict) :local)
                       relay-conflict-test--local))))))

(ert-deftest relay-conflict-ediff-receives-three-independent-snapshots ()
  "Ediff must never use the live visited buffer as LOCAL, REMOTE, or ancestor."
  (let ((buffers (relay-conflict-test--call 'relay-conflict--ediff-buffers
                                               (relay-conflict-test--snapshot))))
    (should (= (length buffers) 3))
    (should (cl-every #'buffer-live-p buffers))
    (should (cl-every (lambda (buffer) (not (eq buffer (current-buffer)))) buffers))
    (should (equal (with-current-buffer (nth 0 buffers) (buffer-string)) "local\n"))
    (should (equal (with-current-buffer (nth 1 buffers) (buffer-string)) "remote\n"))
    (should (equal (with-current-buffer (nth 2 buffers) (buffer-string)) "base\n"))))

(ert-deftest relay-conflict-ediff-launches-one-snapshot-set-and-abandon-keeps-result ()
  "Ediff gets exactly independent A/B/ancestor once; abandon closes UI only."
  (relay-conflict-test--with-buffer
    (let* ((snapshot (relay-conflict-test--snapshot))
           (calls nil) (quit 0) (merge (generate-new-buffer " *relay merge test*")))
      (setq relay-conflict--state snapshot)
      (require 'ediff)
      (cl-letf (((symbol-function 'ediff-merge-buffers-with-ancestor)
                 (lambda (a b ancestor &rest _) (setq calls (list a b ancestor))
                   (setq ediff-buffer-C merge))))
        (let ((relay-conflict--ediff-quit-function (lambda () (setq quit (1+ quit))))
              (result (relay-conflict-test--call 'relay-conflict--start-ediff snapshot)))
          (should (eq result merge))
          (should (= (length calls) 3))
          (should-not (memq (current-buffer) calls))
          (should (equal (with-current-buffer (nth 0 calls) (buffer-string)) "local\n"))
          (with-current-buffer merge
            (should relay-conflict-merge-mode)
            (should (eq (lookup-key relay-conflict-merge-mode-map (kbd "C-c C-k"))
                        #'relay-conflict-abandon-merge))
            (relay-conflict-abandon-merge))
          (should (= quit 1))
          (should (buffer-live-p merge))
          (should (equal relay-conflict--state snapshot)))))))

(ert-deftest relay-conflict-merge-apply-refuses-modified-live-buffer ()
  "Ediff apply never overwrites edits made in the visited buffer while merging."
  (relay-conflict-test--with-buffer
    (let* ((snapshot (relay-conflict-test--snapshot))
           (changed (relay-conflict-test--bytes "user changed again\n"))
           (_ (erase-buffer)) (_ (insert "user changed again\n"))
           (result (relay-conflict-test--call 'relay-conflict--apply-merge
                                                 snapshot relay-conflict-test--local changed)))
      (should (eq (plist-get result :status) 'live-changed))
      (should (buffer-live-p (plist-get result :merge-recovery)))
      (should (equal (plist-get relay-conflict--state :local) changed))
      (should (equal (plist-get relay-conflict--state :merge-recovery)
                     (plist-get result :merge-recovery))))))

(ert-deftest relay-conflict-merge-apply-refuses-changed-remote ()
  "Ediff apply checks the fetched REMOTE revision immediately before writing."
  (relay-conflict-test--with-buffer
    (let* ((snapshot (relay-conflict-test--snapshot))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (new-remote (list :bytes (relay-conflict-test--bytes "remote two\n")
                             :revision (relay-conflict-test--revision 'replacement)))
           (relay-conflict--fetch-function (lambda () new-remote))
           (result (relay-conflict-test--call 'relay-conflict--apply-merge
                                                 snapshot relay-conflict-test--local
                                                 relay-conflict-test--local)))
      (should (eq (plist-get result :status) 'remote-changed))
      (should (buffer-live-p (plist-get result :merge-recovery)))
      (should (equal (plist-get relay-conflict--state :remote) new-remote)))))

(ert-deftest relay-conflict-merge-apply-success-updates-live-base-and-closes-ediff ()
  "A verified merge writes against REMOTE, installs its revision, and closes Ediff."
  (relay-conflict-test--with-buffer
    (erase-buffer) (insert "local\n")
    (let* ((live (current-buffer))
           (snapshot (relay-conflict-test--snapshot))
           (merged (relay-conflict-test--bytes "merged\n"))
           (new-revision (relay-conflict-test--revision 'replacement))
           (merge-buffer (generate-new-buffer " *relay apply merge test*"))
           (quit 0)
           seen)
      (setq relay-conflict--base (plist-get snapshot :base))
      (setq relay-conflict--state snapshot)
      (with-current-buffer merge-buffer
        (insert "merged\n")
        (setq-local relay-conflict--merge-snapshot snapshot)
        (setq-local relay-conflict--merge-live-buffer live)
        (relay-conflict-merge-mode 1)
        (let ((relay-conflict--fetch-function
               (lambda () (plist-get snapshot :remote)))
              (relay-conflict--request-function
               (lambda (op args)
                 (setq seen (list op args))
                 (list :ok t :revision new-revision)))
              (relay-conflict--ediff-quit-function
               (lambda () (setq quit (1+ quit)))))
          (should (eq (plist-get (relay-conflict-apply-merge) :status) 'saved))))
      (should (= quit 1))
      (should (equal (car seen) "write"))
      (should (equal (plist-get (cadr seen) :bytes) merged))
      (should (equal (plist-get (cadr seen) :expected_revision)
                     (plist-get (plist-get snapshot :remote) :revision)))
      (should (equal (buffer-string) "merged\n"))
      (should (equal (plist-get relay-conflict--base :bytes) merged))
      (should (equal (plist-get relay-conflict--base :revision) new-revision))
      (should-not relay-conflict--state)
      (should-not (buffer-modified-p))
      (should (buffer-live-p merge-buffer)))))

(ert-deftest relay-conflict-merge-second-write-conflict-preserves-result-and-refreshes ()
  "A race during merge publication retains MERGED and refreshes REMOTE state."
  (relay-conflict-test--with-buffer
    (erase-buffer) (insert "local\n")
    (let* ((snapshot (relay-conflict-test--snapshot))
           (merged (relay-conflict-test--bytes "merged\n"))
           (fresh (list :bytes (relay-conflict-test--bytes "remote two\n")
                        :revision (relay-conflict-test--revision 'replacement)))
           (fetches (list (plist-get snapshot :remote) fresh))
           (relay-conflict--fetch-function (lambda () (pop fetches)))
           (relay-conflict--request-function
            (lambda (&rest _)
              (list :ok nil :error_code "conflict"
                    :conflict (list :kind "changed"
                                    :current_revision (plist-get fresh :revision)))))
           (result (relay-conflict--apply-merge
                    snapshot merged relay-conflict-test--local)))
      (should (eq (plist-get result :status) 'conflict))
      (should (equal (plist-get relay-conflict--state :remote) fresh))
      (should (buffer-live-p (plist-get result :merge-recovery)))
      (should (equal (with-current-buffer (plist-get result :merge-recovery)
                       (buffer-string))
                     "merged\n")))))

(ert-deftest relay-conflict-merge-verification-read-failure-never-writes ()
  "Failure to verify REMOTE keeps the merge unresolved and issues no write."
  (relay-conflict-test--with-buffer
    (erase-buffer) (insert "local\n")
    (let* ((snapshot (relay-conflict-test--snapshot))
           (relay-conflict--fetch-function (lambda () (error "offline")))
           (relay-conflict--request-function (lambda (&rest _) (ert-fail "blind merge write")))
           (result (relay-conflict--apply-merge
                    snapshot (relay-conflict-test--bytes "merged\n")
                    relay-conflict-test--local)))
      (should (eq (plist-get result :status) 'uncertain))
      (should (equal (plist-get relay-conflict--state :reason) "transport")))))

(ert-deftest relay-conflict-auto-revert-clean-buffer-fetches-and-advances-base ()
  "With Auto-Revert, clean LOCAL is freshly fetched then installed as BASE."
  (relay-conflict-test--with-buffer
    (let* ((new (relay-conflict-test--revision 'remote))
           (relay-conflict--base (list :bytes relay-conflict-test--base :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
           (relay-conflict--fetch-function (lambda () (list :bytes relay-conflict-test--remote :revision new)))
           (result (relay-conflict-test--call 'relay-conflict--auto-revert t)))
      (should (eq (plist-get result :status) 'reverted))
      (should (equal (buffer-string) "remote\n"))
      (should (equal (plist-get relay-conflict--base :revision) new)))))

(ert-deftest relay-conflict-auto-revert-dirty-buffer-never-fetches-or-reloads ()
  "With Auto-Revert, dirty LOCAL stays untouched and BASE stays historical."
  (relay-conflict-test--with-buffer
    (let* ((base (list :bytes relay-conflict-test--base :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
           (relay-conflict--base base)
           (relay-conflict--fetch-function (lambda () (ert-fail "dirty auto-revert read remote")))
           (_ (erase-buffer)) (_ (insert "local\n"))
           (result (relay-conflict-test--call 'relay-conflict--auto-revert t)))
      (should (eq (plist-get result :status) 'deferred))
      (should (equal (buffer-string) "local\n"))
      (should (equal relay-conflict--base base)))))

(ert-deftest relay-conflict-disabled-auto-revert-performs-no-read ()
  "Without Auto-Revert, server events do not fetch content or alter BASE."
  (relay-conflict-test--with-buffer
    (let* ((base (list :bytes relay-conflict-test--base :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
           (relay-conflict--base base)
           (relay-conflict--fetch-function (lambda () (ert-fail "disabled auto-revert read remote")))
           (result (relay-conflict-test--call 'relay-conflict--auto-revert nil)))
      (should (eq (plist-get result :status) 'ignored))
      (should (equal relay-conflict--base base)))))

(ert-deftest relay-conflict-transport-ambiguity-adopts-equal-local ()
  "After lost reply, equal intended LOCAL and remote means saved without retry."
  (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--reconcile-uncertain
                                                       relay-conflict-test--base relay-conflict-test--local
                                                       relay-conflict-test--local (relay-conflict-test--revision 'remote))
                         :status) 'saved)))

(ert-deftest relay-conflict-transport-ambiguity-offers-explicit-retry-at-base ()
  "After lost reply, unchanged remote retains LOCAL and offers an explicit retry."
  (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--reconcile-uncertain
                                                       relay-conflict-test--base relay-conflict-test--local
                                                       relay-conflict-test--base (relay-conflict-test--revision 'base))
                         :status) 'retry)))

(ert-deftest relay-conflict-transport-ambiguity-third-version-is-a-conflict ()
  "After lost reply, a third remote version enters normal conflict handling."
  (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--reconcile-uncertain
                                                       relay-conflict-test--base relay-conflict-test--local
                                                       relay-conflict-test--remote (relay-conflict-test--revision 'remote))
                         :status) 'conflict)))

(ert-deftest relay-conflict-old-server-capability-mismatch-is-actionable ()
  "A hello reply without revisions-v1 fails before any write with reinstall help."
  (let ((message (condition-case err
                     (progn (relay-conflict-test--call 'relay-conflict--require-capability '(:server_version "old")) nil)
                   (error (error-message-string err)))))
    (should (string-match-p "reinstall" (downcase message)))
    (should (string-match-p "revisions-v1" message))))

(ert-deftest relay-conflict-old-server-protocol-mismatch-is-actionable ()
  "A pre-versioning hello (no protocol_version field) fails before file
operations and points to reinstall."
  (let ((message (condition-case err
                     (progn
                       (relay--require-protocol-version
                        '(:capabilities ("revisions-v1")))
                       nil)
                   (error (error-message-string err)))))
    (should (string-match-p "protocol" (downcase message)))
    (should (string-match-p "reinstall" (downcase message)))
    (should (string-match-p "1" message))))

(defun relay-conflict-test--stop-connections (connections)
  "Stop every server process owned by a test-local CONNECTIONS table."
  (maphash (lambda (_authority connection)
             (let ((process (relay-conn-process connection)))
               (when (and (processp process) (process-live-p process))
                 (delete-process process))))
           connections))

(ert-deftest relay-conflict-two-buffer-local-server-yields-one-save-one-conflict ()
  "Two independently visited local-transport buffers contend through real handlers.

The future conflict save handler must issue two writes based on one BASE.  The
server's mutation lock must admit exactly one and return a structured conflict
for the other.  This is intentionally a real local-server fixture, not a
simulation; current builds fail red before the first planned save call."
  (let* ((binary (expand-file-name "server/target/debug/relay-server"
                                    relay-conflict-test--root))
         (relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path binary)
         (local (make-temp-file "relay-conflict-two-buffer-" nil ".txt" "base\n"))
         (remote (format "/relay:local:%s" local))
         first second)
    (unwind-protect
        (progn
          (unless (file-executable-p binary)
            (ert-skip (format "local relay server is not built: %s" binary)))
          (setq first (find-file-noselect remote))
          ;; `find-file-noselect' canonicalizes one file to one buffer.  A
          ;; second explicit visit is needed to model a second user/buffer.
          (setq second (generate-new-buffer " *relay-conflict-second*"))
          (with-current-buffer second
            (insert-file-contents remote)
            (setq buffer-file-name remote)
            (set-visited-file-modtime)
            (set-buffer-modified-p nil))
          (with-current-buffer first
            (erase-buffer) (insert "first local\n")
            (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--save)
                                   :status) 'saved)))
          (with-current-buffer second
            (erase-buffer) (insert "second local\n")
            (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--save)
                                   :status) 'conflict))))
      (dolist (buffer (delq nil (list first second)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (relay-conflict-test--stop-connections relay--connections)
      (when (file-exists-p local) (delete-file local)))))

(ert-deftest relay-conflict-missing-visit-installs-create-only-base-and-detects-appearance ()
  "A real missing visit installs a missing BASE and never overwrites an appearance."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-conflict-test--root))
         (local (make-temp-file "relay-conflict-missing-"))
         (remote (format "/relay:local:%s" local)) buffer)
    (unwind-protect
        (progn
          (delete-file local)
          (setq buffer (find-file-noselect remote))
          (with-current-buffer buffer
            (should (relay-conflict--revision-missing-p
                     (plist-get relay-conflict--base :revision)))
            (should (memq #'relay-conflict--write-contents write-contents-functions))
            ;; A separate creator wins the create race.
            (with-temp-file local (insert "other\n"))
            (insert "local\n")
            (let ((result (relay-conflict--save)))
              (should (eq (plist-get result :status) 'conflict))
              (should (equal (plist-get (plist-get result :conflict) :reason) "appeared")))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (relay-conflict-test--stop-connections relay--connections)
      (when (file-exists-p local) (delete-file local)))))

(ert-deftest relay-conflict-external-edit-conflicts-with-auto-revert-on-and-off ()
  "A remote change has the same save result regardless of notification mode.

This drives the genuine planned save entry point against its deterministic
request backend; Auto-Revert itself is covered above and is deliberately not
the correctness mechanism here."
  (dolist (auto-revert '(t nil))
    (relay-conflict-test--with-buffer
      (let* ((relay-conflict--base
              (list :bytes relay-conflict-test--base
                    :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
             (relay-conflict--request-function
              (lambda (_operation _arguments)
                (list :ok nil :error_code "conflict"
                      :conflict (list :kind "changed"
                                      :current_revision (relay-conflict-test--revision 'remote)))))
             (_ (erase-buffer)) (_ (insert "local\n"))
             (auto-result (relay-conflict--auto-revert auto-revert))
             (result (relay-conflict-test--call 'relay-conflict--save)))
        (should (eq (plist-get auto-result :status)
                    (if auto-revert 'deferred 'ignored)))
        (should (eq (plist-get result :status) 'conflict))
        (should (equal (plist-get relay-conflict--base :bytes)
                       relay-conflict-test--base))))))

(ert-deftest relay-conflict-remote-deletion-never-silently-recreates-path ()
  "Delete/modify is a deletion conflict; only an explicit choice may recreate it."
  (let ((menu (relay-conflict-test--call 'relay-conflict--menu-state (list :kind "deleted"))))
    (should (eq (plist-get menu :kind) 'deleted))
    (should (member 'keep-remote (plist-get menu :choices)))
    (should (member 'save-as (plist-get menu :choices)))))

(ert-deftest relay-conflict-auto-revert-deletion-preserves-live-and-base ()
  "A clean Auto-Revert read failure for a deletion is deferred, never adopted."
  (relay-conflict-test--with-buffer
    (let* ((base (list :bytes relay-conflict-test--base
                       :revision (relay-conflict-test--revision 'base) :coding 'utf-8))
           (relay-conflict--base base)
           (relay-conflict--fetch-function (lambda () (error "deleted")))
           (result (relay-conflict-test--call 'relay-conflict--auto-revert t)))
      (should (eq (plist-get result :status) 'deferred))
      (should (equal (buffer-string) "base\n"))
      (should (equal relay-conflict--base base)))))

(ert-deftest relay-conflict-handler-revert-deletion-preserves-live-and-base ()
  "A real handler replace read must not turn remote deletion into empty content."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-conflict-test--root))
         (local (make-temp-file "relay-conflict-revert-delete-" nil ".txt" "base\n"))
         (remote (format "/relay:local:%s" local)) buffer)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect remote))
          (with-current-buffer buffer
            (let ((base relay-conflict--base))
              (delete-file local)
              (should-error (relay--h-insert-file-contents remote t nil nil t))
              (should (equal (buffer-string) "base\n"))
              (should (equal relay-conflict--base base)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
      (relay-conflict-test--stop-connections relay--connections)
      (when (file-exists-p local) (delete-file local)))))

(ert-deftest relay-conflict-deleted-remote-writes-against-missing-state ()
  "Keep Local on deletion uses missing expected state, never a legacy write."
  (let* ((snapshot (relay-conflict-test--snapshot))
         (snapshot (plist-put snapshot :remote
                              (list :bytes "" :revision (list :schema 1 :state "missing") :deleted t)))
         seen
         (relay-conflict--request-function
          (lambda (_op args) (setq seen args) (list :ok t :revision (relay-conflict-test--revision 'replacement)))))
    (should (eq (plist-get (relay-conflict-test--call 'relay-conflict--resolve snapshot 'keep-local)
                           :status) 'saved))
    (should (equal (plist-get seen :expected_revision) (list :schema 1 :state "missing")))))

(ert-deftest relay-conflict-whole-file-resolutions-retain-recovery-buffers ()
  "All destructive resolutions publish read-only recovery buffers until killed."
  (let ((relay-conflict--request-function
         (lambda (_op _args) (list :ok t :revision (relay-conflict-test--revision 'replacement)))))
   (dolist (choice '(keep-remote restore-base))
    (let* ((result (relay-conflict-test--call 'relay-conflict--resolve
                                                (relay-conflict-test--snapshot) choice))
           (buffers (delq nil (list (plist-get result :local-recovery)
                                    (plist-get result :remote-recovery)))))
      (should buffers)
      (dolist (buffer buffers)
        (should (buffer-live-p buffer))
        (should (with-current-buffer buffer buffer-read-only)))))))

(provide 'relay-conflict-tests)
;;; relay-conflict-tests.el ends here

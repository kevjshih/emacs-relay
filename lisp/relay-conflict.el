;;; relay-conflict.el --- Revision-safe saves for relay -*- lexical-binding: t; -*-

;; This module owns the per-buffer three-way state.  It deliberately keeps the
;; transport boundary small: tests may bind the two backend functions below,
;; while normal buffers use the ordinary relay request path.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'relay-core)

;; Defined by ediff.el, which is intentionally loaded only when merge is used.
(defvar ediff-buffer-C nil)
(defvar ediff-control-buffer nil)
(defvar ediff-keep-variants nil)

(defvar-local relay-conflict--base nil
  "Last known good snapshot: (:bytes :revision :coding).")
(defvar-local relay-conflict--state nil
  "Unresolved conflict snapshot for the current visited buffer.")
(defvar-local relay-conflict--pending-read nil
  "A just-read revision awaiting explicit visitation by the caller.")
(defvar relay-conflict--request-function nil
  "Optional test backend called with OP and decoded argument plist.")
(defvar relay-conflict--fetch-function nil
  "Optional test backend returning (:bytes BYTES :revision REVISION).")

(declare-function relay--content-cache-put "relay-content-prefetch"
                  (authority localpath bytes &optional revision))
(declare-function relay--content-cache-evict "relay-content-prefetch" (key))

(defun relay-conflict--bytes ()
  "Return the current buffer encoded as the supported raw UTF-8 bytes."
  (encode-coding-string (buffer-substring-no-properties (point-min) (point-max)) 'utf-8))

(defun relay-conflict--plist-without (plist property)
  "Return PLIST without PROPERTY, compatible with older supported Emacsen."
  (let (result)
    (while plist
      (unless (eq (car plist) property)
        (setq result (append result (list (car plist) (cadr plist)))))
      (setq plist (cddr plist)))
    result))

(defun relay-conflict--record-base (bytes revision &optional coding)
  "Record BYTES and REVISION as this buffer's last known good BASE."
  (setq relay-conflict--base
        (list :bytes bytes :revision revision :coding (or coding 'utf-8))))

(defun relay-conflict--revision-missing-p (revision)
  (equal (plist-get revision :state) "missing"))

(defun relay-conflict--write-arguments (bytes revision purpose append must-be-new)
  "Build a decoded write argument plist for BYTES.

PURPOSE is `visited' for the ordinary save path and `unvisited' otherwise.
Append and must-be-new writes intentionally retain the old protocol behavior."
  (cond
   (append (list :bytes bytes :append t))
   (must-be-new (list :bytes bytes :must_be_new t))
   ((eq purpose 'visited) (list :bytes bytes :expected_revision revision))
   (t (list :bytes bytes :legacy t))))

(defun relay-conflict--rpc (op arguments)
  "Issue OP with decoded ARGUMENTS, using the deterministic test hook if set."
  (if relay-conflict--request-function
      (condition-case err
          (funcall relay-conflict--request-function op arguments)
        (error (list :ok nil :transport t :error (error-message-string err))))
    (let* ((p (and buffer-file-name (relay--parse buffer-file-name)))
           (args (copy-sequence arguments))
           (bytes (plist-get args :bytes))
           (target (or (plist-get args :path) (and p (cdr p)))))
      (unless p (error "relay conflict save requires a visited relay file"))
      (when (plist-get args :path)
        (let ((target-remote (relay--parse target)))
          (when target-remote
            (unless (equal (car target-remote) (car p))
              (error "Save As must use the same relay authority"))
            (setq target (cdr target-remote)))))
      (setq args (relay-conflict--plist-without args :path))
      (when (plist-member args :bytes)
        (setq args (plist-put (relay-conflict--plist-without args :bytes) :bytes_b64
                              (base64-encode-string bytes t))))
      ;; Tests retain the complete missing revision as an internal value; the
      ;; wire protocol deliberately spells that create-only precondition as a
      ;; compact `expected_state: missing'.
      (when (relay-conflict--revision-missing-p (plist-get args :expected_revision))
        (setq args (plist-put (relay-conflict--plist-without args :expected_revision)
                              :expected_state "missing")))
      (condition-case err
          (apply #'relay--request (relay--connection (car p)) op
                 (append (list :path target) args))
        (relay-request-error
         (or (nth 2 err) (list :ok nil :error (error-message-string err))))
        (error (list :ok nil :transport t :error (error-message-string err)))))))

(defun relay-conflict--fetch ()
  "Fetch fresh raw bytes and revision, bypassing any content-prefetch cache."
  (if relay-conflict--fetch-function
      (funcall relay-conflict--fetch-function)
    (let ((reply (relay-conflict--rpc "read" nil)))
      (if (plist-get reply :ok)
          (list :bytes (base64-decode-string (plist-get reply :bytes_b64))
                :revision (plist-get reply :revision))
        (error "%s" (or (plist-get reply :error) "unable to read remote file"))))))

(defun relay-conflict--classify (base local remote &optional remote-revision)
  "Classify BASE, LOCAL, and REMOTE using bytes rather than dirty flags."
  (cond
   ((equal local remote)
    (if remote-revision
        (list :kind 'convergent :revision remote-revision :action 'adopt-remote)
      'unchanged))
   ((equal local base) 'remote-only)
   ((equal remote base) 'local-only)
   (t 'divergent)))

(defun relay-conflict--menu-state (conflict)
  "Return allowed resolution choices for CONFLICT's server-provided kind."
  (let* ((value (or (plist-get conflict :kind) "changed"))
         (kind (if (symbolp value) value (intern value))))
    (list :kind kind
          :choices (if (eq kind 'type_changed)
                       '(save-as cancel)
                     '(keep-local keep-remote restore-base merge save-as cancel)))))

(defun relay-conflict--reply-reason (reply)
  "Return a safe conflict reason for failed conditional-write REPLY.

Unsupported types, encodings, and oversized files share the restricted menu:
they may be saved elsewhere or cancelled, but never overwritten or merged."
  (or (plist-get (plist-get reply :conflict) :kind)
      (and (member (plist-get reply :error_code)
                   '("unsupported_file_type" "unsupported_encoding" "file_too_large"))
           "type_changed")))

(defun relay-conflict--recovery-buffer (label bytes)
  "Create a visible, read-only recovery buffer containing BYTES."
  (let ((buffer (generate-new-buffer (format "*relay %s recovery*" label))))
    (with-current-buffer buffer
      (insert (decode-coding-string bytes 'utf-8))
      (setq buffer-read-only t))
    (display-buffer buffer)
    buffer))

(defun relay-conflict--cache (bytes revision)
  "Update the revision-aware cache for the current visited file."
  (when (and (fboundp 'relay--content-cache-put) buffer-file-name)
    (let ((p (relay--parse buffer-file-name)))
      (when p (relay--content-cache-put (car p) (cdr p) bytes revision)))))

(defun relay-conflict--refresh-visited-modtime ()
  "Refresh Emacs's visited timestamp after a confirmed remote state change."
  (when (and (not relay-conflict--request-function)
             buffer-file-name
             (relay--parse buffer-file-name))
    (ignore-errors (set-visited-file-modtime))))

(defun relay-conflict--replace-live (bytes revision)
  "Replace current visited buffer with BYTES and record REVISION as BASE."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (decode-coding-string bytes 'utf-8)))
  (relay-conflict--record-base bytes revision 'utf-8)
  (relay-conflict--cache bytes revision)
  (setq relay-conflict--state nil)
  (set-buffer-modified-p nil)
  (relay-conflict--refresh-visited-modtime))

(defun relay-conflict--snapshot (reason &optional remote classification)
  "Capture the live conflict state, optionally with already fetched REMOTE."
  (list :reason reason :base relay-conflict--base :local (relay-conflict--bytes)
        :remote remote :classification classification))

(defun relay-conflict--fresh-conflict (snapshot reply)
  "Refresh SNAPSHOT after a second conflict response REPLY."
  (let ((reason (or (relay-conflict--reply-reason reply) "changed")))
    (condition-case nil
      (let* ((remote (relay-conflict--fetch))
             (base (plist-get (plist-get snapshot :base) :bytes))
             (local (plist-get snapshot :local))
             (classification
              (relay-conflict--classify base local (plist-get remote :bytes)
                                          (plist-get remote :revision))))
        (list :reason reason
              :base (plist-get snapshot :base) :local (plist-get snapshot :local)
              :remote remote :classification classification))
      (error (if (equal reason "deleted")
                 (list :reason reason :base (plist-get snapshot :base)
                       :local (plist-get snapshot :local)
                       :remote (list :bytes "" :revision (list :schema 1 :state "missing")
                                     :deleted t))
               snapshot)))))

(defun relay-conflict--write-snapshot (bytes revision &optional path)
  "Write BYTES conditionally on REVISION and return its decoded reply."
  (let ((arguments (relay-conflict--write-arguments bytes revision 'visited nil nil)))
    (when path (setq arguments (plist-put arguments :path path)))
    (relay-conflict--rpc "write" arguments)))

(defun relay-conflict--save-internal ()
  "Conditionally save this visited buffer, retaining BASE on every failure."
  (let* ((base relay-conflict--base)
         (local (relay-conflict--bytes))
         (retry-state (and (eq (plist-get relay-conflict--state :status) 'retry)
                           relay-conflict--state)))
    ;; A manually constructed visited buffer (not an ordinary `find-file'
    ;; visit) can legitimately reach us without installation.  Fetch once to
    ;; establish a BASE; normal visits never use this fallback.
    (unless base
      (when (and relay-conflict--pending-read
                 (equal buffer-file-name (plist-get relay-conflict--pending-read :filename)))
        (setq base (relay-conflict--record-base
                    (plist-get relay-conflict--pending-read :bytes)
                    (plist-get relay-conflict--pending-read :revision) 'utf-8))
        (setq relay-conflict--pending-read nil)))
    (unless base
      (condition-case nil
          (let ((remote (relay-conflict--fetch)))
            (setq base (relay-conflict--record-base
                        (plist-get remote :bytes) (plist-get remote :revision) 'utf-8)))
        (error nil)))
    (if (not base)
        (list :status 'uncertain :reason 'missing-base
              :error "Cannot save safely: no revision BASE is available"))
      (let* ((retry-remote (and retry-state (plist-get retry-state :remote)))
             (retry-revision (and retry-remote (plist-get retry-remote :revision)))
             ;; A second user-initiated save is the explicit retry.  It may use
             ;; the revision proven by the ambiguity read, but only while both
             ;; the historical BASE and captured LOCAL remain unchanged.
             (expected (if (and retry-revision
                                (equal (plist-get retry-state :base) base)
                                (equal (plist-get retry-state :local) local))
                           retry-revision
                         (plist-get base :revision)))
             (reply (relay-conflict--write-snapshot local expected)))
        (cond
         ((plist-get reply :ok)
          (relay-conflict--record-base local (plist-get reply :revision) (plist-get base :coding))
          (relay-conflict--cache local (plist-get reply :revision))
          (setq relay-conflict--state nil)
          (set-buffer-modified-p nil)
          (relay-conflict--refresh-visited-modtime)
          (list :status 'saved :revision (plist-get reply :revision)))
         ((plist-get reply :transport)
          ;; Never retry the write.  Reconnect/read once and classify the
          ;; observed remote bytes against the intended LOCAL and old BASE.
          (condition-case nil
              (let* ((remote (relay-conflict--fetch))
                     (outcome (relay-conflict--reconcile-uncertain
                               (plist-get base :bytes) local (plist-get remote :bytes)
                               (plist-get remote :revision))))
                (pcase (plist-get outcome :status)
                  ('saved
                   (relay-conflict--record-base local (plist-get remote :revision)
                                                   (plist-get base :coding))
                   (relay-conflict--cache local (plist-get remote :revision))
                   (set-buffer-modified-p nil)
                   (relay-conflict--refresh-visited-modtime)
                   outcome)
                  ('conflict
                   (let ((conflict (relay-conflict--snapshot "changed" remote)))
                     (setq relay-conflict--state conflict)
                     (list :status 'conflict :conflict conflict)))
                  (_ (plist-put outcome :remote remote))))
            ;; Reconnection/read failure leaves BASE and LOCAL untouched.
            (error (list :status 'uncertain :reason 'transport
                         :error (concat "Save outcome is uncertain; reconnect and inspect remote: "
                                        (or (plist-get reply :error) "transport failure"))))))
         ((relay-conflict--reply-reason reply)
          (let* ((reason (relay-conflict--reply-reason reply))
                 (remote (condition-case nil (relay-conflict--fetch)
                           (error (and (equal reason "deleted")
                                       (list :bytes "" :revision (list :schema 1 :state "missing")
                                             :deleted t)))))
                 (classification (and remote
                                      (relay-conflict--classify
                                       (plist-get base :bytes) local (plist-get remote :bytes)
                                       (plist-get remote :revision))))
                 (conflict (relay-conflict--snapshot reason remote classification)))
            (if (and (listp classification) (eq (plist-get classification :kind) 'convergent))
                (progn
                  (relay-conflict--replace-live (plist-get remote :bytes)
                                                  (plist-get remote :revision))
                  (list :status 'saved :revision (plist-get remote :revision)))
              (setq relay-conflict--state conflict)
              (list :status 'conflict :conflict conflict))))
         (t
          (list :status 'uncertain :reason 'server-error
                :error (or (plist-get reply :error)
                           "Server could not verify the conditional save")))))))

(defun relay-conflict--remember-incomplete-save (result)
  "Persist unresolved retry/uncertain save facts without advancing BASE."
  (when (memq (plist-get result :status) '(retry uncertain))
    (setq relay-conflict--state
          (list :status (plist-get result :status)
                :reason (plist-get result :reason)
                :base relay-conflict--base
                :local (relay-conflict--bytes)
                :remote (plist-get result :remote)
                :revision (plist-get result :revision)
                :error (plist-get result :error)))
    (setq result (plist-put result :conflict relay-conflict--state)))
  result)

(defun relay-conflict--save ()
  "Conditionally save and persist any unresolved retry/uncertain outcome."
  (relay-conflict--remember-incomplete-save
   (relay-conflict--save-internal)))

(defun relay-conflict--revert (remote)
  "Install fresh REMOTE in a clean buffer and establish the new BASE."
  (relay-conflict--replace-live (plist-get remote :bytes) (plist-get remote :revision))
  (list :status 'reverted))

(defun relay-conflict--auto-revert (enabled)
  "Perform the conflict-safe Auto-Revert decision for the current buffer."
  (cond ((not enabled) (list :status 'ignored))
        ((not (equal (relay-conflict--bytes)
                     (plist-get relay-conflict--base :bytes)))
         (list :status 'deferred))
        (t (condition-case nil
               (relay-conflict--revert (relay-conflict--fetch))
             ;; A remote deletion is not an Auto-Revert instruction: preserve
             ;; bytes and historical BASE until the user explicitly adopts it.
             (error (list :status 'deferred :reason 'deleted))))))

(defun relay-conflict--reconcile-uncertain (base local remote revision)
  "Classify remote bytes after a lost write reply without retrying the write."
  (cond ((equal local remote) (list :status 'saved :reason 'remote-matches-local :revision revision))
        ((equal base remote) (list :status 'retry :reason 'remote-matches-base :revision revision
                                   :error "Remote still equals BASE; retry explicitly when ready"))
        (t (list :status 'conflict :reason 'third-version :revision revision))))

(defun relay-conflict--require-capability (hello)
  "Reject a server that cannot enforce revision conditional writes."
  (relay--require-revision-capability hello)
  t)

(defun relay-conflict--ediff-buffers (snapshot)
  "Return independent LOCAL, REMOTE, and BASE buffers for SNAPSHOT."
  (cl-labels ((make (name bytes)
                (let ((buffer (generate-new-buffer (format " *relay %s*" name))))
                  (with-current-buffer buffer (insert (decode-coding-string bytes 'utf-8)))
                  buffer)))
    (list (make "local" (plist-get snapshot :local))
          (make "remote" (plist-get (plist-get snapshot :remote) :bytes))
          (make "base" (plist-get (plist-get snapshot :base) :bytes)))))

(defun relay-conflict--start-ediff (snapshot)
  "Start a three-way Ediff session over independent SNAPSHOT buffers."
  (require 'ediff)
  (let ((origin (current-buffer)))
    (pcase-let ((`(,local ,remote ,base) (relay-conflict--ediff-buffers snapshot)))
      (ediff-merge-buffers-with-ancestor local remote base)
      ;; Ediff creates C synchronously before it hands control to its setup
      ;; machinery.  Mark only that editable result, never the live visit.
      (when (buffer-live-p ediff-buffer-C)
        (with-current-buffer ediff-buffer-C
          (setq-local relay-conflict--merge-snapshot snapshot)
          (setq-local relay-conflict--merge-live-buffer origin)
          (setq-local relay-conflict--merge-control-buffer ediff-control-buffer)
          (relay-conflict-merge-mode 1)))
      ediff-buffer-C)))

(define-minor-mode relay-conflict-merge-mode
  "Minor mode for a pending relay conflict merge buffer."
  :lighter " EMerge"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'relay-conflict-apply-merge)
            (define-key map (kbd "C-c C-k") #'relay-conflict-abandon-merge)
            map))

(defvar-local relay-conflict--merge-snapshot nil)
(defvar-local relay-conflict--merge-live-buffer nil)
(defvar-local relay-conflict--merge-control-buffer nil)
(defvar relay-conflict--ediff-quit-function nil
  "Optional test seam used to close an Ediff control session.")

(defun relay-conflict--close-ediff ()
  "Close Ediff UI without killing the editable merge result buffer."
  (cond (relay-conflict--ediff-quit-function
         (funcall relay-conflict--ediff-quit-function))
        ((and (fboundp 'ediff-quit)
              (buffer-live-p relay-conflict--merge-control-buffer))
         (let ((control relay-conflict--merge-control-buffer))
           (with-current-buffer control
             (let ((ediff-keep-variants t))
               (ignore-errors (ediff-quit nil))))))))

(defun relay-conflict--merge-recovery (bytes)
  (relay-conflict--recovery-buffer "merge" bytes))

(defun relay-conflict--merge-refusal (snapshot merged status reason &optional remote)
  "Retain MERGED and refresh live conflict state after a refused apply.

SNAPSHOT supplies the historical BASE.  STATUS is the caller-facing result
and REASON describes why the merge could not be published.  REMOTE, when
non-nil, is the fresh snapshot observed while verifying the apply."
  (let* ((recovery (relay-conflict--merge-recovery merged))
         (local (relay-conflict--bytes))
         (remote (or remote (plist-get snapshot :remote)))
         (base (plist-get snapshot :base))
         (classification
          (and remote
               (relay-conflict--classify
                (plist-get base :bytes) local (plist-get remote :bytes)
                (plist-get remote :revision))))
         (conflict (list :reason reason :base base :local local :remote remote
                         :classification classification
                         :merge-recovery recovery)))
    (setq relay-conflict--state conflict)
    (list :status status :conflict conflict :merge-recovery recovery)))

(defun relay-conflict--apply-merge (snapshot merged live-bytes)
  "Apply MERGED only if LIVE-BYTES and the remote revision still match SNAPSHOT."
  (if (not (equal live-bytes (plist-get snapshot :local)))
      (relay-conflict--merge-refusal snapshot merged 'live-changed "live_changed")
    (let ((remote (condition-case nil (relay-conflict--fetch) (error nil))))
      (cond
       ((not remote)
        (relay-conflict--merge-refusal snapshot merged 'uncertain "transport"))
       ((not (equal (plist-get remote :revision)
                    (plist-get (plist-get snapshot :remote) :revision)))
        (relay-conflict--merge-refusal snapshot merged 'remote-changed "changed" remote))
       (t
        (let ((reply (relay-conflict--write-snapshot
                      merged (plist-get (plist-get snapshot :remote) :revision))))
          (cond
           ((plist-get reply :ok)
            (relay-conflict--replace-live merged (plist-get reply :revision))
            (list :status 'saved :revision (plist-get reply :revision)))
           ((plist-get reply :transport)
            ;; As with an ordinary save, never retry an ambiguous write.  A
            ;; read proving that MERGED reached the server is sufficient to
            ;; adopt it; all other outcomes stay unresolved.
            (let ((after (condition-case nil (relay-conflict--fetch) (error nil))))
              (if (and after (equal merged (plist-get after :bytes)))
                  (progn
                    (relay-conflict--replace-live merged (plist-get after :revision))
                    (list :status 'saved :revision (plist-get after :revision)))
                (relay-conflict--merge-refusal
                 snapshot merged 'uncertain "transport" after))))
           (t
            (let ((fresh (relay-conflict--fresh-conflict snapshot reply)))
              (relay-conflict--merge-refusal
               fresh merged 'conflict (plist-get fresh :reason)
               (plist-get fresh :remote)))))))))))

(defun relay-conflict-apply-merge ()
  "Apply the current merge result to its originating live buffer."
  (interactive)
  (let* ((snapshot relay-conflict--merge-snapshot)
         (live relay-conflict--merge-live-buffer)
         (merged (relay-conflict--bytes))
         (result (with-current-buffer live
                   (relay-conflict--apply-merge snapshot merged (relay-conflict--bytes)))))
    (unless (eq (plist-get result :status) 'saved)
      (message "relay merge was not applied; the result is preserved"))
    (when (eq (plist-get result :status) 'saved) (relay-conflict--close-ediff))
    result))

(defun relay-conflict-abandon-merge ()
  "Leave a merge result intact while retaining the original unresolved state."
  (interactive)
  (when (buffer-live-p relay-conflict--merge-live-buffer)
    (let ((snapshot relay-conflict--merge-snapshot))
      (with-current-buffer relay-conflict--merge-live-buffer
        (unless relay-conflict--state
          (setq relay-conflict--state snapshot)))))
  (relay-conflict--close-ediff)
  (relay-conflict-merge-mode -1)
  (message "relay conflict merge abandoned; conflict remains unresolved"))

(defun relay-conflict--resolve (snapshot choice &optional save-as)
  "Resolve SNAPSHOT with CHOICE, always using its fetched REMOTE revision."
  (let* ((base (plist-get snapshot :base))
         (local (plist-get snapshot :local))
         (remote (plist-get snapshot :remote))
         (remote-bytes (plist-get remote :bytes))
         (remote-revision (plist-get remote :revision)))
    (pcase choice
      ('cancel (setq relay-conflict--state snapshot) (list :status 'cancelled :conflict snapshot))
      ('keep-remote
       (let ((recovery (relay-conflict--recovery-buffer "local" local)))
         (if (and remote (not (plist-get remote :deleted)))
             (relay-conflict--replace-live remote-bytes remote-revision)
           ;; Remote deletion is an explicit adoption of the missing state;
           ;; it never recreates the path and LOCAL remains recoverable.
           (relay-conflict--replace-live "" (list :schema 1 :state "missing")))
         (list :status 'adopted-remote :local-recovery recovery)))
      ;; Snapshot buffers are allocated only by the actual Ediff launch path;
      ;; allocating here as well used to leak a duplicate A/B/ancestor set.
      ('merge (list :status 'merge :conflict snapshot))
      ((or 'keep-local 'restore-base 'save-as)
       (let* ((bytes (pcase choice
                       ('keep-local local) ('restore-base (plist-get base :bytes)) (_ local)))
              (expected (if (eq choice 'save-as) (list :schema 1 :state "missing") remote-revision))
              (local-recovery (and (eq choice 'restore-base)
                                   (relay-conflict--recovery-buffer "local" local)))
              (remote-recovery (and (eq choice 'restore-base)
                                    (relay-conflict--recovery-buffer "remote" (or remote-bytes ""))))
              (reply (relay-conflict--write-snapshot bytes expected save-as)))
         (if (plist-get reply :ok)
             (if (eq choice 'save-as)
                 (progn
                   (setq relay-conflict--state snapshot)
                   (list :status 'saved-as :conflict snapshot))
               (progn (relay-conflict--record-base bytes (plist-get reply :revision) 'utf-8)
                      (setq relay-conflict--state nil)
                      (if (eq choice 'restore-base)
                          (relay-conflict--replace-live bytes (plist-get reply :revision))
                        (progn
                          (relay-conflict--cache bytes (plist-get reply :revision))
                          (when (equal (relay-conflict--bytes) bytes)
                            (set-buffer-modified-p nil))))
                      (list :status 'saved :local-recovery local-recovery :remote-recovery remote-recovery)))
           (if (relay-conflict--reply-reason reply)
               (let ((fresh (relay-conflict--fresh-conflict snapshot reply)))
                 (setq relay-conflict--state fresh)
                 (list :status 'conflict :conflict fresh))
             (setq relay-conflict--state snapshot)
             (list :status 'uncertain :error (plist-get reply :error)
                   :conflict snapshot)))))
      (_ (error "Unknown relay conflict resolution: %S" choice)))))

(defun relay-conflict--write-contents ()
  "Buffer-local `write-contents-functions' implementation for visited saves."
  (when (and buffer-file-name (relay--parse buffer-file-name) relay-conflict--base)
    (let ((result (relay-conflict--save)))
      (pcase (plist-get result :status)
        ('saved t)
        ('conflict (if (not noninteractive)
                       (let ((resolution (relay-conflict--interactive-menu
                                          (plist-get result :conflict))))
                         (if (memq (plist-get resolution :status) '(saved adopted-remote))
                             t
                           (error "relay conflict remains unresolved")))
                     (error "relay save conflict")))
        (_ (error "relay save is uncertain: %s" (or (plist-get result :error) "unknown error")))))))

(defun relay-conflict--interactive-menu (snapshot)
  "Present the compact one-key whole-file conflict menu for SNAPSHOT."
  (let* ((choices (plist-get (relay-conflict--menu-state (list :kind (plist-get snapshot :reason))) :choices))
         (keys (delq nil (mapcar (lambda (pair) (and (memq (cdr pair) choices) (car pair)))
                                 '((?l . keep-local) (?r . keep-remote) (?b . restore-base)
                                   (?m . merge) (?s . save-as) (?q . cancel)))))
         (remote-only (eq (plist-get snapshot :classification) 'remote-only))
         (key (read-char-choice
               (concat "relay conflict: "
                       (mapconcat (lambda (pair) (format "[%c]%s" (car pair) (cdr pair)))
                                  (seq-filter (lambda (pair) (memq (cdr pair) choices))
                                              '((?l . "local") (?r . "remote") (?b . "base")
                                                (?m . "merge") (?s . "save as") (?q . "quit"))) " ")
                       (and remote-only " [RET] remote") " ")
               (append keys (and remote-only '(?\r)))))
         (choice (cdr (assq key '((?l . keep-local) (?r . keep-remote) (?b . restore-base)
                                  (?m . merge) (?s . save-as) (?q . cancel))))))
    (when (and remote-only (eq key ?\r)) (setq choice 'keep-remote))
    (unless (member choice choices) (user-error "That resolution is unavailable for this conflict"))
    (let ((result (relay-conflict--resolve
                   snapshot choice
                   (and (eq choice 'save-as) (read-file-name "Save local as: ")))))
      (when (eq choice 'merge) (relay-conflict--start-ediff snapshot))
      (if (eq (plist-get result :status) 'conflict)
          (relay-conflict--interactive-menu (plist-get result :conflict))
        result))))

(defun relay-conflict--install-buffer (bytes revision &optional coding)
  "Install conflict handling in a successfully visited relay file buffer."
  (relay-conflict--record-base bytes revision coding)
  (add-hook 'write-contents-functions #'relay-conflict--write-contents nil t))

(provide 'relay-conflict)
;;; relay-conflict.el ends here

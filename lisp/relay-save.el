;;; relay-save.el --- Nonblocking interactive Relay saves -*- lexical-binding: t; -*-

;;; Commentary:

;; `save-buffer' remains synchronous when called directly.  This module only
;; remaps the interactive binding in visited Relay buffers, preserving Emacs's
;; compatibility contract while moving the network round trip off the command
;; path.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'relay-core)
(require 'relay-conflict)

(defvar relay-async-save-mode)

(defcustom relay-save-success-visible-seconds 2.0
  "Seconds a confirmed asynchronous save remains visible in the mode line."
  :type 'number :group 'relay)

(defvar-local relay-save--active nil
  "Captured asynchronous operation currently in flight.")
(defvar-local relay-save--queued nil
  "Latest captured save requested while `relay-save--active' is in flight.")
(defvar-local relay-save--generation 0
  "Monotonic generation used to reject stale callbacks.")
(defvar-local relay-save--status nil
  "Current asynchronous UI status symbol.")
(defvar-local relay-save--result nil
  "Most recent terminal asynchronous result plist.")
(defvar-local relay-save--success-timer nil)
(defvar-local relay-save--header-was-local nil)
(defvar-local relay-save--saved-header-line-format nil)
(defvar-local relay-save--header-component nil)
(defvar-local relay-save--preparing nil)

(defun relay-save--lighter ()
  "Return the dynamic lighter for the current Relay buffer."
  (pcase relay-save--status
    ('saving " Saving…")
    ('saved " ✓ Saved")
    ('saved-newer " ✓ Saved; newer edits not saved")
    ('conflict " ⚠ Save conflict")
    ('unknown " ? Save status unknown")
    ('failed " ✕ Save failed")
    (_ "")))

(defun relay-save--header-banner ()
  "Return an actionable save banner, or nil for routine states."
  (pcase relay-save--status
    ('conflict " Save conflict — C-x C-s to resolve ")
    ('unknown " Save status unknown — C-x C-s to inspect ")
    ('failed " Save failed — C-x C-s to retry ")
    (_ nil)))

(defun relay-save--install-header ()
  "Compose Relay's actionable banner with the buffer's existing header."
  (unless relay-save--header-component
    (setq relay-save--header-was-local (local-variable-p 'header-line-format)
          relay-save--saved-header-line-format header-line-format
          relay-save--header-component '(:eval (relay-save--header-banner)))
    ;; Nest the old value as one format element.  Flattening it would corrupt
    ;; a common top-level `(:eval FORM)' header by appending inside that form.
    (setq-local header-line-format
                (list header-line-format relay-save--header-component))))

(defun relay-save--remove-header ()
  "Restore the header value present before async save mode was enabled."
  (when relay-save--header-component
    (if relay-save--header-was-local
        (setq-local header-line-format relay-save--saved-header-line-format)
      (kill-local-variable 'header-line-format))
    (setq relay-save--header-component nil)))

(defun relay-save--cancel-success-timer ()
  (when (timerp relay-save--success-timer)
    (cancel-timer relay-save--success-timer))
  (setq relay-save--success-timer nil))

(defun relay-save--selected-p ()
  "Non-nil when the current buffer is selected in the selected window."
  (eq (current-buffer) (window-buffer (selected-window))))

(defun relay-save--expire-success (buffer generation)
  "Expire BUFFER's success lighter if it still belongs to GENERATION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (= generation relay-save--generation)
                 (eq relay-save--status 'saved))
        (setq relay-save--status nil relay-save--success-timer nil)
        (force-mode-line-update t)))))

(defun relay-save--start-success-timer-if-visible ()
  "Start the success timer only after this buffer is actually selected."
  (when (and (eq relay-save--status 'saved)
             (not relay-save--success-timer)
             (relay-save--selected-p))
    (setq relay-save--success-timer
          (run-at-time relay-save-success-visible-seconds nil
                       #'relay-save--expire-success
                       (current-buffer) relay-save--generation))))

(defun relay-save--post-command ()
  (relay-save--start-success-timer-if-visible))

(defun relay-save--set-status (status &optional result)
  "Set buffer-local STATUS and terminal RESULT, updating its local UI."
  (relay-save--cancel-success-timer)
  (setq relay-save--status status relay-save--result result)
  (force-mode-line-update t)
  ;; An outer `save-buffer' wrapper can print its synchronous progress text
  ;; after this command has returned.  Clear that exact stale progress at the
  ;; terminal callback, but never erase an unrelated diagnostic.
  (let ((visible (current-message)))
    (when (and (not (eq status 'saving))
               (relay-save--selected-p)
               (stringp visible)
               (string-prefix-p "Saving file " visible))
      (message nil)))
  (when (eq status 'saved)
    (relay-save--start-success-timer-if-visible)))

(defun relay-save--killed-message (status identity)
  "Report terminal STATUS for killed buffer IDENTITY via the minibuffer."
  (let ((name (plist-get identity :filename)))
    (message
     (pcase status
       ('saved "Relay saved %s (originating buffer was killed)")
       ('saved-newer "Relay saved %s; newer edits were not saved")
       ('conflict "Relay save conflict for %s (originating buffer was killed)")
       ('unknown "Relay save status unknown for %s (originating buffer was killed)")
       (_ "Relay save failed for %s (originating buffer was killed)"))
     name)))

(defun relay-save--identity-equal-p (left right)
  "Non-nil when LEFT and RIGHT name the exact same Relay target."
  (and left right
       (equal (plist-get left :authority) (plist-get right :authority))
       (equal (plist-get left :path) (plist-get right :path))))

(defun relay-save--live-identity-equal-p (identity)
  (relay-save--identity-equal-p identity (relay-conflict--file-identity)))

(defun relay-save--operation-target (operation)
  "Return OPERATION's actual remote target identity."
  (or (plist-get operation :target-identity)
      (plist-get operation :identity)))

(defun relay-save--cache-identity (identity bytes revision)
  "Cache BYTES and REVISION for captured IDENTITY, not the live filename."
  (when (fboundp 'relay--content-cache-put)
    (relay--content-cache-put (plist-get identity :authority)
                              (plist-get identity :path) bytes revision)))

(defun relay-save--cache-identity-safely (identity bytes revision)
  "Update the optional content cache without changing a save outcome."
  (condition-case err
      (relay-save--cache-identity identity bytes revision)
    (error
     (display-warning
      'relay (format "Relay saved the file, but could not update its cache: %s"
                     (error-message-string err))
      :warning))))

(defun relay-save--run-after-save-hook ()
  "Run `after-save-hook' without hiding an already confirmed remote write."
  (condition-case err
      (run-hooks 'after-save-hook)
    (error
     (display-warning
      'relay (format "Relay saved the file, but an after-save hook failed: %s"
                     (error-message-string err))
      :warning))))

(defun relay-save--revision-time (revision)
  "Return REVISION's exact mtime as an Emacs time value."
  (let ((time (time-convert (or (plist-get revision :mtime_sec) 0) 'list))
        (nsec (or (plist-get revision :mtime_nsec) 0)))
    (setf (nth 2 time) (/ nsec 1000)
          (nth 3 time) (* (% nsec 1000) 1000))
    time))

(defun relay-save--set-visited-metadata (revision)
  "Update visited metadata directly from REVISION without a remote stat."
  (when (and revision (plist-member revision :mtime_sec))
    (condition-case nil
        (set-visited-file-modtime (relay-save--revision-time revision))
      (error nil))))

(defun relay-save--ensure-final-newline ()
  "Apply the visited-save final-newline behavior before snapshot capture."
  (let ((requirement (if (local-variable-p 'mode-require-final-newline)
                         mode-require-final-newline
                       require-final-newline)))
    (when (and requirement (> (point-max) (point-min))
               (not (eq (char-before (point-max)) ?\n))
               (or (eq requirement t)
                   (y-or-n-p (format "Add a newline at end of %s? "
                                     (buffer-name)))))
      (goto-char (point-max))
      (insert "\n"))))

(defun relay-save--capture (&optional base expected)
  "Run local pre-save work and return a captured operation snapshot."
  (let ((identity (relay-conflict--file-identity)))
    (unless identity (user-error "Current buffer is not visiting a Relay file"))
    (save-restriction
      (widen)
      (save-excursion
        (let ((relay-save--preparing t))
          (relay-save--ensure-final-newline)
          (run-hooks 'before-save-hook)))
      (let ((base (or base relay-conflict--base)))
        (unless base (user-error "Cannot save safely: no revision BASE is available"))
        (list :buffer (current-buffer)
              :identity identity
              :bytes (relay-conflict--bytes)
              :base base
              :expected (or expected (plist-get base :revision)))))))

(defun relay-save--same-request-p (left right)
  (and left right
       (relay-save--identity-equal-p (plist-get left :identity)
                                     (plist-get right :identity))
       (equal (plist-get left :bytes) (plist-get right :bytes))))

(defun relay-save--operation-current-p (operation)
  "Non-nil when OPERATION is still this buffer's active generation."
  (and (eq operation relay-save--active)
       (= (plist-get operation :generation) relay-save--generation)))

(defun relay-save--snapshot-conflict (operation reason &optional remote)
  "Build conflict state for OPERATION, REASON, and optional REMOTE."
  (let* ((prior (plist-get operation :snapshot))
         (base (or (plist-get prior :base) (plist-get operation :base)))
         (local (or (plist-get prior :local) (plist-get operation :bytes)))
         (classification
          (and remote
               (relay-conflict--classify
                (plist-get base :bytes) local (plist-get remote :bytes)
                (plist-get remote :revision)))))
    (append (list :reason reason :base base :local local :remote remote
                  :classification classification)
            (when (plist-get operation :local-recovery)
              (list :local-recovery (plist-get operation :local-recovery)))
            (when (plist-get operation :remote-recovery)
              (list :remote-recovery (plist-get operation :remote-recovery))))))

(defun relay-save--finish-nonsuccess (operation status result &optional conflict)
  "Finish OPERATION with non-success STATUS and RESULT."
  (let ((buffer (plist-get operation :buffer))
        (identity (plist-get operation :identity)))
    (if (not (buffer-live-p buffer))
        (relay-save--killed-message status identity)
      (with-current-buffer buffer
        (when (relay-save--operation-current-p operation)
          (setq relay-save--active nil relay-save--queued nil)
          (when conflict (setq relay-conflict--state conflict))
          (set-buffer-modified-p t)
          (relay-save--set-status status result))))))

(defun relay-save--callback-error (operation err)
  "Turn unexpected callback ERR for OPERATION into a terminal safe state."
  (display-warning
   'relay (format "Relay asynchronous save callback failed: %s"
                  (error-message-string err))
   :error)
  (if (plist-get operation :merge-buffer)
      (relay-save--merge-refusal operation 'uncertain "client_error")
    (let ((state (list :status 'uncertain :reason 'client-error
                       :base (plist-get operation :base)
                       :local (plist-get operation :bytes)
                       :error (error-message-string err))))
      (relay-save--finish-nonsuccess operation 'unknown state state))))

(defun relay-save--guarded-callback (operation function)
  "Return a callback applying FUNCTION safely for OPERATION."
  (lambda (&rest arguments)
    (condition-case err
        (apply function arguments)
      (error (relay-save--callback-error operation err)))))

(defun relay-save--finish-success (operation revision &optional status-extra)
  "Confirm OPERATION at REVISION and dispatch its latest queued successor."
  (let ((buffer (plist-get operation :buffer))
        (identity (or (plist-get operation :target-identity)
                      (plist-get operation :identity)))
        (bytes (plist-get operation :bytes)))
    (relay-save--cache-identity-safely identity bytes revision)
    (if (not (buffer-live-p buffer))
        (relay-save--killed-message 'saved identity)
      (with-current-buffer buffer
        (when (relay-save--operation-current-p operation)
          (let* ((choice (plist-get operation :choice))
                 (source-identity (plist-get operation :identity))
                 (same-file (relay-save--live-identity-equal-p source-identity))
                 (same-bytes (and same-file (equal (relay-conflict--bytes) bytes)))
                 (queued relay-save--queued))
            (setq relay-save--active nil relay-save--queued nil)
            (cond
             ((eq choice 'save-as)
              ;; The original path remains conflicted and modified.  Save As
              ;; only confirms the separate captured target.
              (set-buffer-modified-p t)
              (relay-save--set-status
               'conflict (list :status 'saved-as :revision revision
                               :conflict relay-conflict--state)))
             ((and (eq choice 'restore-base) same-file
                   (equal (relay-conflict--bytes)
                          (plist-get (plist-get operation :snapshot) :local)))
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (decode-coding-string bytes 'utf-8)))
              (relay-conflict--record-base
               bytes revision (plist-get (plist-get operation :base) :coding))
              (setq relay-conflict--state nil)
              (relay-save--set-visited-metadata revision)
              (set-buffer-modified-p nil)
              (relay-save--run-after-save-hook)
              (relay-save--set-status
               (if (equal (relay-conflict--bytes) bytes) 'saved 'saved-newer)
               (list :status 'saved :revision revision
                     :newer-edits (not (equal (relay-conflict--bytes) bytes)))))
             (t
              (when same-file
                (relay-conflict--record-base
                 bytes revision (plist-get (plist-get operation :base) :coding))
                (setq relay-conflict--state nil)
                (relay-save--set-visited-metadata revision))
              (if same-bytes
                  (progn
                    (set-buffer-modified-p nil)
                    (relay-save--run-after-save-hook)
                    (unless (equal (relay-conflict--bytes) bytes)
                      (setq same-bytes nil)
                      (set-buffer-modified-p t)))
                (set-buffer-modified-p t))
              (if (and queued same-file
                       (relay-save--identity-equal-p
                        source-identity (plist-get queued :identity)))
                  (progn
                    (setq queued (plist-put queued :base
                                            (list :bytes bytes :revision revision
                                                  :coding (plist-get
                                                           (plist-get operation :base)
                                                           :coding))))
                    (setq queued (plist-put queued :expected revision))
                    (set-buffer-modified-p t)
                    (relay-save--dispatch queued))
                (relay-save--set-status
                 (if (and same-bytes (not status-extra)) 'saved 'saved-newer)
                 (list :status 'saved :revision revision
                       :newer-edits (not same-bytes))))))))))))

(defun relay-save--remote-result (reply)
  "Decode a successful asynchronous read REPLY."
  (and (plist-get reply :ok)
       (list :bytes (plist-get reply :bytes)
             :revision (plist-get reply :revision))))

(defun relay-save--reconcile-transport (operation failure)
  "Reconcile an ambiguous write FAILURE without retrying OPERATION."
  (relay-conflict--fetch-async
   (relay-save--operation-target operation)
   (relay-save--guarded-callback
    operation
    (lambda (reply)
     (let ((buffer (plist-get operation :buffer)))
       (when (or (not (buffer-live-p buffer))
                 (with-current-buffer buffer
                   (relay-save--operation-current-p operation)))
         (if (not (plist-get reply :ok))
             (relay-save--finish-nonsuccess
              operation 'unknown
              (list :status 'uncertain :reason 'transport
                    :error (or (plist-get failure :error)
                               "Save outcome is unknown")))
           (let* ((base (plist-get (plist-get operation :base) :bytes))
                  (local (plist-get operation :bytes))
                  (remote (list :bytes (plist-get reply :bytes)
                                :revision (plist-get reply :revision)))
                  (outcome (relay-conflict--reconcile-uncertain
                            base local (plist-get remote :bytes)
                            (plist-get remote :revision))))
             (pcase (plist-get outcome :status)
               ('saved
                (relay-save--finish-success operation (plist-get remote :revision)))
               ('retry
                (let ((state (list :status 'retry :reason (plist-get outcome :reason)
                                   :base (plist-get operation :base)
                                   :local local :remote remote
                                   :revision (plist-get remote :revision)
                                   :error (plist-get outcome :error))))
                  (relay-save--finish-nonsuccess operation 'unknown outcome state)))
               (_
                (let ((conflict (relay-save--snapshot-conflict
                                 operation "changed" remote)))
                  (relay-save--finish-nonsuccess
                   operation 'conflict
                   (list :status 'conflict :conflict conflict) conflict))))))))))))

(defun relay-save--handle-conflict (operation reply)
  "Fetch and install actionable conflict state after conditional REPLY."
  (let ((reason (or (relay-conflict--reply-reason reply) "changed")))
    (relay-conflict--fetch-async
     (relay-save--operation-target operation)
     (relay-save--guarded-callback
      operation
      (lambda (read-reply)
       (let ((buffer (plist-get operation :buffer)))
         (when (or (not (buffer-live-p buffer))
                   (with-current-buffer buffer
                     (relay-save--operation-current-p operation)))
           (if (and (not (plist-get read-reply :ok))
                    (not (equal reason "deleted")))
               (relay-save--finish-nonsuccess
                operation 'failed
                (list :status 'failed :reason 'conflict-read
                      :error (or (plist-get read-reply :error)
                                 "Could not read the conflicting remote file")))
             (let* ((remote
                     (if (plist-get read-reply :ok)
                         (list :bytes (plist-get read-reply :bytes)
                               :revision (plist-get read-reply :revision))
                       (list :bytes ""
                             :revision (list :schema 1 :state "missing")
                             :deleted t)))
                    (conflict (relay-save--snapshot-conflict operation reason remote))
                    (classification (plist-get conflict :classification)))
               (if (and (listp classification)
                        (eq (plist-get classification :kind) 'convergent))
                   (relay-save--finish-success operation (plist-get remote :revision))
                 (relay-save--finish-nonsuccess
                  operation 'conflict
                  (list :status 'conflict :conflict conflict) conflict)))))))))))

(defun relay-save--write-done (operation reply)
  "Handle terminal conditional write REPLY for OPERATION."
  (let ((buffer (plist-get operation :buffer)))
    (when (or (not (buffer-live-p buffer))
              (with-current-buffer buffer
                (relay-save--operation-current-p operation)))
      (cond
       ((plist-get reply :ok)
        (relay-save--finish-success operation (plist-get reply :revision)
                                    (plist-get operation :status-extra)))
       ((plist-get reply :transport)
        (relay-save--reconcile-transport operation reply))
       ((relay-conflict--reply-reason reply)
        (relay-save--handle-conflict operation reply))
       (t
        (relay-save--finish-nonsuccess
         operation 'failed
         (list :status 'failed :reason 'server-error
               :error (or (plist-get reply :error) "Relay save failed"))))))))

(defun relay-save--dispatch (operation)
  "Dispatch captured OPERATION and return immediately."
  (setq operation (plist-put operation :generation (cl-incf relay-save--generation))
        relay-save--active operation)
  (relay-save--set-status 'saving)
  ;; Preserve the ordinary modified marker for the entire network flight.
  (set-buffer-modified-p t)
  (condition-case err
      (relay-conflict--write-snapshot-async
       (plist-get operation :identity)
       (plist-get operation :bytes)
       (plist-get operation :expected)
       (relay-save--guarded-callback
        operation (lambda (reply) (relay-save--write-done operation reply)))
       (plist-get operation :save-as))
    (error (relay-save--callback-error operation err)))
  operation)

(defun relay-save--queue-or-dispatch (operation)
  "Coalesce OPERATION with an active request, or dispatch it now."
  (if relay-save--active
      (cond
       ((relay-save--same-request-p operation relay-save--active)
        ;; The newest requested snapshot is already in flight.  It supersedes
        ;; and cancels any older, different queued snapshot.
        (setq relay-save--queued nil)
        relay-save--active)
       ((relay-save--same-request-p operation relay-save--queued)
        relay-save--queued)
       (t
        (setq relay-save--queued operation)
        operation))
    (relay-save--dispatch operation)))

(defun relay-save--retry-state-operation ()
  "Capture an explicit retry against the revision proven by reconciliation."
  (let* ((state relay-conflict--state)
         (remote (plist-get state :remote))
         (operation (relay-save--capture (plist-get state :base)
                                         (plist-get remote :revision))))
    (if (equal (plist-get operation :bytes) (plist-get state :local))
        operation
      ;; Edits after an ambiguous result invalidate its special retry revision.
      (plist-put operation :expected
                 (plist-get (plist-get state :base) :revision)))))

(defun relay-save--inspect-unknown ()
  "Inspect an unknown save result without retrying its write."
  (let* ((state relay-conflict--state)
         (identity (relay-conflict--file-identity))
         (operation (list :buffer (current-buffer) :identity identity
                          :bytes (plist-get state :local)
                          :base (plist-get state :base))))
    (setq operation (plist-put operation :generation (cl-incf relay-save--generation))
          relay-save--active operation)
    (relay-save--set-status 'saving)
    (condition-case err
        (relay-conflict--fetch-async
         identity
         (relay-save--guarded-callback
          operation
          (lambda (reply)
            (if (not (plist-get reply :ok))
                (relay-save--finish-nonsuccess operation 'unknown state state)
              (let* ((remote (list :bytes (plist-get reply :bytes)
                                   :revision (plist-get reply :revision)))
                     (outcome (relay-conflict--reconcile-uncertain
                               (plist-get (plist-get state :base) :bytes)
                               (plist-get state :local) (plist-get remote :bytes)
                               (plist-get remote :revision))))
                (pcase (plist-get outcome :status)
                  ('saved (relay-save--finish-success
                           operation (plist-get remote :revision)))
                  ('retry
                   (let ((retry (append (list :status 'retry :remote remote) state)))
                     (relay-save--finish-nonsuccess operation 'unknown outcome retry)))
                  (_
                   (let ((conflict (relay-save--snapshot-conflict
                                    operation "changed" remote)))
                     (relay-save--finish-nonsuccess
                      operation 'conflict outcome conflict)))))))))
      (error (relay-save--callback-error operation err)))))

(defun relay-save--read-conflict-choice (snapshot)
  "Read one existing Relay conflict-menu choice for SNAPSHOT."
  (let* ((choices (plist-get
                   (relay-conflict--menu-state
                    (list :kind (plist-get snapshot :reason))) :choices))
         (pairs '((?l keep-local . "local") (?r keep-remote . "remote")
                  (?b restore-base . "base") (?m merge . "merge")
                  (?s save-as . "save as") (?q cancel . "quit")))
         (available (seq-filter (lambda (entry) (memq (cadr entry) choices)) pairs))
         (remote-only (eq (plist-get snapshot :classification) 'remote-only))
         (key (read-char-choice
               (concat "relay conflict: "
                       (mapconcat (lambda (entry)
                                    (format "[%c]%s" (car entry) (cddr entry)))
                                  available " ")
                       (and remote-only " [RET] remote") " ")
               (append (mapcar #'car available) (and remote-only '(?\r))))))
    (if (and remote-only (eq key ?\r))
        'keep-remote
      (cadr (assq key available)))))

(defun relay-save--resolution-operation (snapshot choice &optional save-as)
  "Build asynchronous write operation resolving SNAPSHOT with CHOICE."
  (let* ((base (plist-get snapshot :base))
         (remote (plist-get snapshot :remote))
         (bytes (pcase choice
                  ('restore-base (plist-get base :bytes))
                  (_ (plist-get snapshot :local))))
         (identity (relay-conflict--file-identity))
         (expected (if (eq choice 'save-as)
                       (list :schema 1 :state "missing")
                     (plist-get remote :revision)))
         (target-identity
          (when save-as
            (let ((parsed (relay--parse save-as)))
              (if parsed
                  (list :filename save-as :authority (car parsed) :path (cdr parsed))
                (list :filename (relay--wrap (plist-get identity :authority) save-as)
                      :authority (plist-get identity :authority) :path save-as)))))
         (operation (list :buffer (current-buffer) :identity identity
                          :bytes bytes :base base :expected expected
                          :choice choice :snapshot snapshot)))
    (when (eq choice 'save-as)
      (unless (equal (plist-get target-identity :authority)
                     (plist-get identity :authority))
        (user-error "Save As must use the same Relay authority"))
      (setq operation (plist-put operation :save-as save-as)
            operation (plist-put operation :target-identity target-identity)
            operation (plist-put operation :status-extra t)))
    (when (eq choice 'restore-base)
      ;; Recovery exists before publication and is retained on every failure.
      (setq operation
            (plist-put operation :local-recovery
                       (relay-conflict--recovery-buffer
                        "local" (plist-get snapshot :local))))
      (when (plist-get remote :bytes)
        (setq operation
              (plist-put operation :remote-recovery
                         (relay-conflict--recovery-buffer
                          "remote" (plist-get remote :bytes))))))
    operation))

(defun relay-save--resolve-ready-conflict ()
  "Open the existing conflict menu and start any chosen async resolution."
  (let* ((snapshot relay-conflict--state)
         (choice (relay-save--read-conflict-choice snapshot)))
    (pcase choice
      ('cancel nil)
      ('merge (relay-conflict--start-ediff snapshot))
      ('keep-remote
       (let* ((local (plist-get snapshot :local))
              (remote (plist-get snapshot :remote))
              (bytes (if (and remote (not (plist-get remote :deleted)))
                         (plist-get remote :bytes) ""))
              (revision (if (and remote (not (plist-get remote :deleted)))
                            (plist-get remote :revision)
                          (list :schema 1 :state "missing")))
              (recovery (relay-conflict--recovery-buffer "local" local))
              (inhibit-read-only t))
         (erase-buffer)
         (insert (decode-coding-string bytes 'utf-8))
         (relay-conflict--record-base bytes revision 'utf-8)
         (relay-save--cache-identity-safely
          (relay-conflict--file-identity) bytes revision)
         (setq relay-conflict--state nil)
         (relay-save--set-visited-metadata revision)
         (set-buffer-modified-p nil)
         (relay-save--set-status
          'saved (list :status 'adopted-remote :local-recovery recovery))))
      ((or 'keep-local 'restore-base 'save-as)
       (let ((save-as (and (eq choice 'save-as)
                           (read-file-name "Save local as: "))))
         (relay-save--dispatch
          (relay-save--resolution-operation snapshot choice save-as)))))))

(defun relay-save--merge-refusal (operation status reason &optional remote)
  "Preserve OPERATION's merge after an asynchronous refusal."
  (let ((live (plist-get operation :buffer))
        (merge (plist-get operation :merge-buffer)))
    (if (not (buffer-live-p live))
        (relay-save--killed-message
         (if (eq status 'conflict) 'conflict 'unknown)
         (plist-get operation :identity))
      (with-current-buffer live
        (when (or (not (plist-member operation :generation))
                  (relay-save--operation-current-p operation))
          (let ((result (relay-conflict--merge-refusal
                         (plist-get operation :snapshot)
                         (plist-get operation :bytes) status reason remote)))
            (setq relay-save--active nil relay-save--queued nil)
            (set-buffer-modified-p t)
            (relay-save--set-status
             (pcase status ('conflict 'conflict) ('uncertain 'unknown) (_ 'failed))
             result)))))
    ;; MERGE and its Ediff session deliberately remain live until publication
    ;; is confirmed.  A separate recovery buffer makes the result robust even
    ;; if the user later abandons Ediff.
    (when (buffer-live-p merge)
      (with-current-buffer merge (set-buffer-modified-p t)))))

(defun relay-save--merge-success (operation revision)
  "Install a confirmed merged OPERATION at REVISION and close Ediff."
  (let ((live (plist-get operation :buffer))
        (merge (plist-get operation :merge-buffer))
        (identity (plist-get operation :identity))
        (merged (plist-get operation :bytes)))
    (relay-save--cache-identity-safely identity merged revision)
    (if (not (buffer-live-p live))
        (relay-save--killed-message 'saved identity)
      (with-current-buffer live
        (when (relay-save--operation-current-p operation)
          (let ((installable
                 (and (relay-save--live-identity-equal-p identity)
                      (equal (relay-conflict--bytes)
                             (plist-get (plist-get operation :snapshot) :local)))))
            (setq relay-save--active nil relay-save--queued nil)
            (when (relay-save--live-identity-equal-p identity)
              (relay-conflict--record-base merged revision 'utf-8)
              (setq relay-conflict--state nil)
              (relay-save--set-visited-metadata revision))
            (if installable
                (progn
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert (decode-coding-string merged 'utf-8)))
                  (set-buffer-modified-p nil)
                  (relay-save--run-after-save-hook)
                  (let ((newer (not (equal (relay-conflict--bytes) merged))))
                    (when newer (set-buffer-modified-p t))
                    (relay-save--set-status
                     (if newer 'saved-newer 'saved)
                     (list :status 'saved :revision revision
                           :newer-edits newer))))
              (set-buffer-modified-p t)
              (relay-save--set-status
               'saved-newer
               (list :status 'saved :revision revision :newer-edits t)))))))
    (when (buffer-live-p merge)
      (with-current-buffer merge
        (relay-conflict--close-ediff)
        (relay-conflict-merge-mode -1)))))

(defun relay-save--merge-write-done (operation reply)
  "Handle asynchronous merge publication REPLY for OPERATION."
  (cond
   ((plist-get reply :ok)
    (relay-save--merge-success operation (plist-get reply :revision)))
   ((plist-get reply :transport)
    ;; The write is never retried.  Only exact REMOTE=MERGED proves success.
    (relay-conflict--fetch-async
     (plist-get operation :identity)
     (relay-save--guarded-callback
      operation
      (lambda (after)
        (if (and (plist-get after :ok)
                 (equal (plist-get operation :bytes) (plist-get after :bytes)))
            (relay-save--merge-success operation (plist-get after :revision))
          (relay-save--merge-refusal
           operation 'uncertain "transport"
           (and (plist-get after :ok)
                (list :bytes (plist-get after :bytes)
                      :revision (plist-get after :revision)))))))))
   ((relay-conflict--reply-reason reply)
    (relay-conflict--fetch-async
     (plist-get operation :identity)
     (relay-save--guarded-callback
      operation
      (lambda (after)
        (relay-save--merge-refusal
         operation 'conflict (or (relay-conflict--reply-reason reply) "changed")
         (and (plist-get after :ok)
              (list :bytes (plist-get after :bytes)
                    :revision (plist-get after :revision))))))))
   (t
    (relay-save--merge-refusal operation 'failed "server_error"))))

(defun relay-save--merge-verified (operation reply)
  "Verify merge OPERATION's captured remote revision from read REPLY."
  (let ((live (plist-get operation :buffer)))
    (cond
     ((or (not (buffer-live-p live))
          (not (with-current-buffer live
                 (and (relay-save--operation-current-p operation)
                      (relay-save--live-identity-equal-p
                       (plist-get operation :identity))
                      (equal (relay-conflict--bytes)
                             (plist-get (plist-get operation :snapshot) :local))))))
      (relay-save--merge-refusal operation 'failed "live_changed"))
     ((not (plist-get reply :ok))
      (relay-save--merge-refusal operation 'uncertain "transport"))
     ((not (equal (plist-get reply :revision)
                  (plist-get (plist-get (plist-get operation :snapshot) :remote)
                             :revision)))
      (relay-save--merge-refusal
       operation 'conflict "changed"
       (list :bytes (plist-get reply :bytes) :revision (plist-get reply :revision))))
     (t
      (relay-conflict--write-snapshot-async
       (plist-get operation :identity) (plist-get operation :bytes)
       (plist-get reply :revision)
       (relay-save--guarded-callback
        operation
        (lambda (write-reply)
          (relay-save--merge-write-done operation write-reply))))))))

(defun relay-save-apply-merge-async ()
  "Publish the current Ediff merge result without blocking Emacs."
  (interactive)
  (let* ((merge (current-buffer))
         (snapshot relay-conflict--merge-snapshot)
         (live relay-conflict--merge-live-buffer)
         (merged (relay-conflict--bytes)))
    (unless (and snapshot (buffer-live-p live))
      (user-error "Relay merge no longer has a live originating buffer"))
    (with-current-buffer live
      (when relay-save--active
        (user-error "A Relay save is already in progress"))
      (let ((operation
             (list :buffer live :merge-buffer merge :snapshot snapshot
                   :identity (relay-conflict--file-identity)
                   :bytes merged :base (plist-get snapshot :base))))
        (if (not (equal (relay-conflict--bytes) (plist-get snapshot :local)))
            (relay-save--merge-refusal operation 'failed "live_changed")
          (setq operation
                (plist-put operation :generation (cl-incf relay-save--generation))
                relay-save--active operation)
          (set-buffer-modified-p t)
          (relay-save--set-status 'saving)
          (condition-case err
              (relay-conflict--fetch-async
               (plist-get operation :identity)
               (relay-save--guarded-callback
                operation
                (lambda (reply) (relay-save--merge-verified operation reply))))
            (error (relay-save--callback-error operation err)))
          operation)))))

;;;###autoload
(defun relay-save-buffer-async ()
  "Save the current visited Relay file asynchronously.

The command returns after local hooks and snapshot capture.  Network writes,
conflict reads, and lost-reply reconciliation finish through callbacks."
  (interactive)
  (unless (and relay-async-save-mode buffer-file-name
               (relay--parse buffer-file-name))
    (user-error "Current buffer is not an asynchronous Relay save buffer"))
  ;; Progress and successful completion live in the mode line.  Clear any
  ;; echo-area text left by an earlier/superseded save path so `Saving file ...'
  ;; cannot linger indefinitely while this request completes asynchronously.
  (when (called-interactively-p 'any)
    (message nil))
  (cond
   ((eq relay-save--status 'conflict)
    (relay-save--resolve-ready-conflict))
   ((and (eq relay-save--status 'unknown)
         (eq (plist-get relay-conflict--state :status) 'retry))
    (relay-save--queue-or-dispatch (relay-save--retry-state-operation)))
   ((eq relay-save--status 'unknown)
    (relay-save--inspect-unknown))
   ((or relay-save--active (buffer-modified-p)
        (eq relay-save--status 'failed))
    (relay-save--queue-or-dispatch (relay-save--capture)))
   (t nil)))

(defvar relay-async-save-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap save-buffer] #'relay-save-buffer-async)
    map))

;;;###autoload
(define-minor-mode relay-async-save-mode
  "Use nonblocking interactive saves in a visited Relay buffer."
  :lighter (:eval (relay-save--lighter))
  :keymap relay-async-save-mode-map
  (if relay-async-save-mode
      (progn
        (unless (and buffer-file-name (relay--parse buffer-file-name))
          (setq relay-async-save-mode nil)
          (user-error "Async Relay saves require a visited Relay file"))
        (relay-save--install-header)
        (add-hook 'post-command-hook #'relay-save--post-command nil t))
    (relay-save--cancel-success-timer)
    (remove-hook 'post-command-hook #'relay-save--post-command t)
    (relay-save--remove-header)))

(defun relay-save--install-buffer ()
  "Enable asynchronous interactive saves for the current visited buffer."
  (when (and buffer-file-name (relay--parse buffer-file-name))
    (relay-async-save-mode 1)))

(provide 'relay-save)
;;; relay-save.el ends here

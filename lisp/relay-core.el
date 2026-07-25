;;; relay-core.el --- Async remote transport core -*- lexical-binding: t; -*-

;; Shared transport, connection, and remote-name primitives for relay.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
;; Advertising files as remote (`file-remote-p' non-nil, correctly) routes
;; dired through its remote-aware branch, which consults connection-local
;; variables (`connection-local-default-application' etc). TRAMP normally
;; pulls this in as a side effect of its own `require'; we don't load TRAMP,
;; so we need it directly.
(require 'files-x)

(defgroup relay nil "Async remote file layer." :group 'files)

(defcustom relay-ssh-executable "ssh"
  "Program used to reach remote hosts. Its config (~/.ssh/config) is honored."
  :type 'string :group 'relay)

(defcustom relay-ssh-extra-args nil
  "Extra args passed to ssh BEFORE the destination.
Leave nil to let ~/.ssh/config fully govern the connection."
  :type '(repeat string) :group 'relay)

(defcustom relay-ssh-connect-timeout 5
  "Seconds SSH may spend establishing a connection.

This is passed to OpenSSH as `ConnectTimeout', with one connection attempt.
Set it to nil to leave connection establishment entirely to SSH configuration."
  :type '(choice (const :tag "Use SSH configuration" nil) positive-integer)
  :group 'relay)

(defcustom relay-connect-timeout 8.0
  "Maximum seconds for transport startup and the protocol hello reply.

Ordinary requests use `relay-request-timeout'; this shorter limit bounds the
interactive pause when completion first touches a missing or broken host."
  :type 'number :group 'relay)

;; Defined by autorevert.el, which need not be loaded just to use relay.
(defvar auto-revert-remote-files)

(defcustom relay-server-remote-path "~/.cache/relay/relay-server"
  "Remote server path installed by `scripts/install-server.sh'."
  :type 'string :group 'relay)

(defcustom relay-server-local-path "relay-server"
  "Path to the server binary for the `local' test transport."
  :type 'string :group 'relay)

(defcustom relay-request-timeout 30.0
  "Seconds to wait for a synchronous server reply before erroring."
  :type 'number :group 'relay)

(defcustom relay-max-frame-bytes (* 32 1024 1024)
  "Largest protocol frame accepted from a relay server.

Frames are length-prefixed, so this prevents a malformed or incompatible peer
from making the process filter retain an unbounded partial reply.  It matches
the server's protocol limit by default."
  :type 'integer :group 'relay)

(defconst relay-protocol-version 1)

(define-error 'relay-request-error "relay request failed")

(defun relay--require-protocol-version (hello)
  "Reject HELLO unless it speaks this client's exact protocol version."
  (unless (equal (plist-get hello :protocol_version) relay-protocol-version)
    (error "relay protocol mismatch; reinstall the matching relay server (need protocol %d)"
           relay-protocol-version)))

(defun relay--require-revision-capability (hello)
  "Reject a peer that cannot enforce revision conditional writes."
  (unless (member "revisions-v1" (plist-get hello :capabilities))
    (error "relay server lacks revisions-v1; reinstall the matching relay server")))

(defun relay--frame-size-allowed-p (size)
  "Non-nil if SIZE is within `relay-max-frame-bytes'."
  (<= size relay-max-frame-bytes))

;;;; ---------------------------------------------------------------------------
;;;; Connection object

(cl-defstruct (relay-conn (:constructor relay--make-conn))
  process authority
  (acc "")                                  ; unibyte frame accumulator
  (next-id 0)
  (pending (make-hash-table))               ; id -> reply plist, or 'waiting
  (dircache (make-hash-table :test 'equal)) ; localdir -> list of entry plists
  (dircache-mtime (make-hash-table :test 'equal)) ; localdir -> directory's own mtime at fetch time
  (cache-epoch 0)                           ; invalidates in-flight cache fills
  (watches (make-hash-table :test 'equal))  ; localdir -> list of (descriptor . callback)
  hello)

(defvar relay--connections (make-hash-table :test 'equal)
  "AUTHORITY string -> `relay-conn'.")

;;;; ---------------------------------------------------------------------------
;;;; Transport / framing

(declare-function relay--handle-event "relay-prefetch" (conn msg))
(declare-function relay--revalidate-marked-on-connect "relay-prefetch" (conn))

(defun relay--auth-command (authority)
  "Return the process command (list) that launches the server for AUTHORITY.
AUTHORITY looks like \"ssh+DEST\" or \"local\"."
  (let* ((plus (string-search "+" authority))
         (type (if plus (substring authority 0 plus) authority))
         (dest (if plus (substring authority (1+ plus)) "")))
    (pcase type
      ("local" (list relay-server-local-path))
      ("ssh" (append (list relay-ssh-executable)
                     relay-ssh-extra-args
                     (when relay-ssh-connect-timeout
                       (list "-o" (format "ConnectTimeout=%d"
                                          relay-ssh-connect-timeout)
                             "-o" "ConnectionAttempts=1"))
                     ;; DEST passed straight to ssh -> ~/.ssh/config applies.
                     (list dest relay-server-remote-path)))
      (_ (error "relay: unknown transport %S in %S" type authority)))))

(defun relay--send (conn obj)
  "Frame and send plist OBJ to CONN's server."
  (let* ((payload (encode-coding-string (json-serialize obj) 'utf-8))
         (len (length payload))
         (header (unibyte-string (logand len #xff)
                                 (logand (ash len -8) #xff)
                                 (logand (ash len -16) #xff)
                                 (logand (ash len -24) #xff))))
    (process-send-string (relay-conn-process conn) (concat header payload))))

(defun relay--filter (proc chunk)
  "Process filter: accumulate CHUNK, deframe, and dispatch complete messages."
  (let ((conn (process-get proc 'relay-conn)))
    (setf (relay-conn-acc conn) (concat (relay-conn-acc conn) chunk))
    (let ((acc (relay-conn-acc conn))
          (done nil))
      (while (and (not done) (>= (length acc) 4))
        (let ((len (logior (aref acc 0)
                            (ash (aref acc 1) 8)
                            (ash (aref acc 2) 16)
                            (ash (aref acc 3) 24))))
          (cond
           ((not (relay--frame-size-allowed-p len))
            ;; The stream cannot safely be resynchronized after an invalid
            ;; announced length.  Drop it rather than retaining its payload.
            (setq acc "" done t)
            (delete-process proc))
           ((< (length acc) (+ 4 len))
            (setq done t))                ; wait for the rest of this frame
           (t
            (let ((payload (substring acc 4 (+ 4 len))))
              (setq acc (substring acc (+ 4 len)))
              (relay--dispatch conn (decode-coding-string payload 'utf-8)))))))
      (setf (relay-conn-acc conn) acc))))

(defun relay--dispatch (conn json)
  "Parse one JSON message and route it (reply -> pending table, event -> cache).

The pending table holds one of three shapes per id: the symbol `waiting'
\(a blocked synchronous `relay--request'), a function (a single-reply
`relay--request-async' callback), or `(stream CHUNK-FN . DONE-FN)' (a
multi-reply `relay--request-stream'). Only the last is new — the first two
are exactly as before; a streaming reply just doesn't remove the id from the
table until its final (no `:more') message arrives, so a request can now
have any number of replies before completing instead of exactly one."
  (let ((msg (json-parse-string json :object-type 'plist :array-type 'list
                                :null-object nil :false-object nil)))
    (let ((id (plist-get msg :id))
          (event (plist-get msg :event)))
      (cond
       (event (relay--handle-event conn msg))
       ((and (integerp id) (> id 0))
        (let ((entry (gethash id (relay-conn-pending conn))))
          (cond
           ((and (consp entry) (eq (car entry) 'stream))
            (if (plist-get msg :more)
                (funcall (cadr entry) msg)
              (remhash id (relay-conn-pending conn))
              (funcall (cddr entry) msg)))
           ((functionp entry)
            ;; Async request: fire its callback.
            (remhash id (relay-conn-pending conn))
            (funcall entry msg))
           ((eq entry 'waiting)
            ;; Sync request: install the reply, releasing the blocked waiter.
            (puthash id msg (relay-conn-pending conn)))
           ;; A timed-out request can still produce a late reply.  Do not
           ;; recreate an unknown id as a pending synchronous request.
           (t nil))))))))

(defun relay--transport-error (proc &optional event)
  "Return the most useful available transport failure for PROC."
  (let* ((buffer (process-get proc 'relay-stderr-buffer))
         (stderr
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (string-trim (buffer-substring-no-properties
                            (max (point-min) (- (point-max) 4096))
                            (point-max))))))
         ;; A process-death check can run just before the separate stderr pipe
         ;; flushes.  Prefer newly arrived stderr over an earlier generic cached
         ;; event so the user still gets "host not found"/"connection refused".
         (message (cond
                   ((not (string-empty-p (or stderr ""))) stderr)
                   ((process-get proc 'relay-transport-error))
                   (t (string-trim (or event "transport exited"))))))
    (setq message (if (string-empty-p message)
                      "transport exited before replying"
                    message))
    (process-put proc 'relay-transport-error message)
    message))

(defun relay--fail-pending (conn failure)
  "Release every pending request on CONN with FAILURE."
  (let ((pending (relay-conn-pending conn)) callbacks removals)
    (maphash
     (lambda (id entry)
       (cond
        ((eq entry 'waiting)
         ;; The synchronous waiter owns removal after it observes this reply.
         (puthash id failure pending))
        ((functionp entry)
         (push id removals)
         (push (cons entry failure) callbacks))
        ((and (consp entry) (eq (car entry) 'stream))
         (push id removals)
         (push (cons (cddr entry) failure) callbacks))))
     pending)
    (dolist (id removals) (remhash id pending))
    ;; User/background callbacks can perform file operations themselves.  Keep
    ;; them outside the process sentinel just as filesystem watch callbacks are.
    (dolist (callback callbacks)
      (run-at-time 0 nil (car callback) (cdr callback)))))

(defun relay--sentinel (proc event)
  (unless (process-live-p proc)
    (let ((conn (process-get proc 'relay-conn)))
      (when conn
        (let ((failure (list :ok nil
                             :error (relay--transport-error proc event)
                             :transport t)))
          (relay--fail-pending conn failure))
        ;; An older process can exit after a replacement connection has already
        ;; been installed.  Never let its sentinel erase the newer connection.
        (when (eq (gethash (relay-conn-authority conn) relay--connections)
                  conn)
          (remhash (relay-conn-authority conn) relay--connections))))))

;;;; ---------------------------------------------------------------------------
;;;; Reentrancy-safe request/response  (the crux this milestone de-risks)

(defun relay--request (conn op &rest args)
  "Send OP with ARGS (a plist) and block until *this* request's reply arrives.
Reentrancy-safe: nested requests get their own id and resolve independently;
`accept-process-output' re-enters the event loop, so nested handler calls and
async events may run mid-wait — we only watch our own id."
  (let* ((id (cl-incf (relay-conn-next-id conn)))
         (pending (relay-conn-pending conn))
         (proc (relay-conn-process conn)))
    (puthash id 'waiting pending)
    (condition-case err
        (relay--send conn (append (list :id id :op op) args))
      (error
       (remhash id pending)
       (error "relay: %s: %s" op
              (if (processp proc)
                  (relay--transport-error proc (error-message-string err))
                (error-message-string err)))))
    (let ((deadline (+ (float-time) relay-request-timeout)))
      (while (eq (gethash id pending) 'waiting)
        (accept-process-output proc 0.1)
        ;; The sentinel normally installs the failure reply.  This explicit
        ;; check closes the small ordering window where process death is visible
        ;; before its sentinel has run.
        (when (and (eq (gethash id pending) 'waiting)
                   (not (process-live-p proc)))
          (puthash id (list :ok nil
                            :error (relay--transport-error proc)
                            :transport t)
                   pending))
        (when (> (float-time) deadline)
          (remhash id pending)
          (error "relay: %s timed out" op)))
      (let ((resp (gethash id pending)))
        (remhash id pending)
        (if (plist-get resp :ok)
            resp
          ;; Preserve structured conflicts for revision-aware callers while
          ;; retaining the normal readable error for existing users.
          (signal 'relay-request-error
                  (list (format "relay: %s: %s" op
                                (or (plist-get resp :error) "unknown error"))
                        resp)))))))

(defun relay--request-async (conn op args callback)
  "Send OP with ARGS and call CALLBACK with the reply plist when it arrives.
Returns immediately; never blocks Emacs. Used for background prefetch and any
non-interactive-path work. Replies are id-matched, so out-of-order server
replies are fine."
  (let ((id (cl-incf (relay-conn-next-id conn))))
    (puthash id callback (relay-conn-pending conn))
    (relay--send conn (append (list :id id :op op) args))
    id))

(defun relay--request-stream (conn op args chunk-fn done-fn)
  "Like `relay--request-async', but OP may reply with any number of chunks
before completing, not just one. CHUNK-FN is called with each intermediate
reply (one carrying `:more'); DONE-FN is called once, with the final reply
\(the one with no `:more'), after which the id is no longer pending. Never
blocks. See `relay--dispatch' for how the pending-table shape distinguishes
this from a plain single-reply async request."
  (let ((id (cl-incf (relay-conn-next-id conn))))
    (puthash id (cons 'stream (cons chunk-fn done-fn)) (relay-conn-pending conn))
    (relay--send conn (append (list :id id :op op) args))
    id))

(defun relay--connection (authority)
  "Return a live connection for AUTHORITY, (re)connecting as needed."
  (let ((conn (gethash authority relay--connections)))
    (if (and conn (process-live-p (relay-conn-process conn)))
        conn
      (relay--connect authority))))

(defun relay--connect (authority)
  ;; `make-process' chdirs the subprocess into `default-directory' — and the
  ;; connection is lazily established on first use, which can happen from
  ;; inside a dired buffer for this very authority (default-directory then
  ;; being an /relay:… string). That is never a real local directory, so
  ;; the chdir fails outright. This subprocess (ssh, or the local server) is
  ;; ours to launch and has nothing to do with the caller's notion of "current
  ;; directory" — always launch it from a real local directory. Reproduced via
  ;; backtrace: a fresh connection's first use from `dired-noselect' failed at
  ;; `make-process' with "Setting current directory: No such file or
  ;; directory, /relay:local:/…".
  (let* ((default-directory temporary-file-directory)
         (cmd (relay--auth-command authority))
         (stderr (get-buffer-create (format " *relay-%s-stderr*" authority))))
    (with-current-buffer stderr
      (let ((inhibit-read-only t)) (erase-buffer)))
    ;; Clear STDERR before launch: a host that fails immediately can write and
    ;; exit before control returns from `make-process'.
    (let* ((proc (make-process
                  :name (format "relay-%s" authority)
                  :command cmd
                  :coding 'binary
                  :connection-type 'pipe
                  :noquery t
                  :stderr stderr ; keep ssh errors off framed stdout
                  :filter #'relay--filter
                  :sentinel #'relay--sentinel))
           (conn (relay--make-conn :process proc :authority authority)))
      (process-put proc 'relay-conn conn)
      (process-put proc 'relay-stderr-buffer stderr)
      (puthash authority conn relay--connections)
      (condition-case err
          (let ((relay-request-timeout relay-connect-timeout))
            (setf (relay-conn-hello conn)
                  (relay--request conn "hello" :version relay-protocol-version))
            (relay--require-protocol-version (relay-conn-hello conn))
            (relay--require-revision-capability (relay-conn-hello conn)))
        (error
         (when (eq (gethash authority relay--connections) conn)
           (remhash authority relay--connections))
         (when (process-live-p proc) (delete-process proc))
         (signal (car err) (cdr err))))
      ;; Directories marked for listing prefetch need re-warming here: a fresh
      ;; server process has no watches and this is a brand new `relay-conn'
      ;; (its dircache starts empty), so without this a reconnect would
      ;; silently leave them lazy until some future visit happened to occur.
      (relay--revalidate-marked-on-connect conn)
      conn)))

;;;; ---------------------------------------------------------------------------
;;;; Name parsing helpers

(defun relay--parse (filename)
  "Split FILENAME into (AUTHORITY . LOCALNAME), or nil if not an /relay: name."
  (when (string-match "\\`/relay:\\([^:]+\\):\\(\\(?:/.*\\|~\\(?:/.*\\)?\\)\\)\\'" filename)
    (cons (match-string 1 filename) (match-string 2 filename))))

(defun relay--dirname (local)
  (directory-file-name (or (file-name-directory (directory-file-name local)) "/")))

(defun relay--basename (local)
  (file-name-nondirectory (directory-file-name local)))

(defun relay--wrap (authority local)
  (format "/relay:%s:%s" authority local))

(provide 'relay-core)
;;; relay-core.el ends here

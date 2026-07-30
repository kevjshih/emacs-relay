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

(defcustom relay-callback-queue-max-length 10000
  "Maximum callbacks a connection may have queued awaiting execution.

Bounds unbounded growth if a peer replies faster than callbacks can run (or a
callback never returns). Exceeding it closes the connection outright, the
same as an oversized frame."
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
  (callback-queue nil)                      ; reverse-order queue of pending zero-arg thunks
  (drain-scheduled nil)                     ; non-nil while a drain timer is pending
  (ready nil)                               ; non-nil once hello has succeeded (both sync and async paths)
  (connect-waiters nil)                     ; list of (on-ready . on-error) pairs awaiting readiness
  hello)

(defvar relay--connections (make-hash-table :test 'equal)
  "AUTHORITY string -> `relay-conn'.")

;;;; ---------------------------------------------------------------------------
;;;; Direct file-notify watch registry
;;
;; A `file-notify-add-watch' registration (dired, `auto-revert-mode') used to
;; live on the specific `relay-conn' that was current when it was added --
;; but a reconnect replaces that conn object entirely with a fresh one whose
;; watch table starts empty, silently dropping the registration with no
;; error and no notification. This registry is keyed by (AUTHORITY .
;; LOCALDIR) instead, so it survives any number of reconnects; the
;; descriptors it hands out are `(AUTHORITY . ID)', never a specific conn.

(defvar relay--direct-watches (make-hash-table :test 'equal)
  "(AUTHORITY . LOCALDIR) -> list of (DESCRIPTOR . CALLBACK).")

(defvar relay--direct-watch-next-id 0
  "Monotonic counter backing descriptors in `relay--direct-watches'.")

(defun relay--direct-watch-add (authority localdir callback)
  "Register CALLBACK for LOCALDIR on AUTHORITY and return its descriptor."
  (let ((descriptor (cons authority (cl-incf relay--direct-watch-next-id))))
    (push (cons descriptor callback)
          (gethash (cons authority localdir) relay--direct-watches))
    descriptor))

(defun relay--direct-watch-remove (descriptor)
  "Remove DESCRIPTOR from `relay--direct-watches'.

Returns the (AUTHORITY . LOCALDIR) key whose watch list just became empty
as a result, or nil otherwise -- callers use this to decide whether to tell
the server to `unwatch' (only when nothing else, e.g. a cached directory
listing, still needs that directory watched)."
  (let (emptied-key)
    (maphash (lambda (key wcs)
               (when (assq descriptor wcs)
                 (let ((remaining (assq-delete-all descriptor wcs)))
                   (puthash key remaining relay--direct-watches)
                   (unless remaining (setq emptied-key key)))))
             relay--direct-watches)
    emptied-key))

(defun relay--direct-watches-for (authority localdir)
  "Return the (DESCRIPTOR . CALLBACK) list registered for LOCALDIR on
AUTHORITY, or nil."
  (gethash (cons authority localdir) relay--direct-watches))

(defun relay--rewatch-direct-on-connect (conn)
  "Re-register CONN's authority's direct watches with the server, and
deliver a synthetic `changed' event to each.

The watch died with the old connection (see `relay--direct-watches''s
header comment); a caller that missed real changes while disconnected needs
a prompt to re-check its own state, the same signal an actual change would
have given it -- this is that prompt."
  (let ((authority (relay-conn-authority conn)))
    (maphash
     (lambda (key wcs)
       (when (and (equal (car key) authority) wcs)
         (let ((localdir (cdr key)))
           (relay--request-async conn "watch" (list :path localdir) #'ignore)
           (dolist (wc wcs)
             (let* ((descriptor (car wc))
                    (callback (cdr wc))
                    (fnevent (list descriptor 'changed
                                   (format "/relay:%s:%s" authority localdir))))
               (run-at-time 0 nil (lambda () (ignore-errors (funcall callback fnevent)))))))))
     relay--direct-watches)))

;;;; ---------------------------------------------------------------------------
;;;; Deferred callback queue
;;
;; `relay--dispatch' parses and routes each frame inline in the process
;; filter, but must not run application callbacks there -- a slow callback
;; would otherwise stall ingestion of the rest of an already-received chunk
;; (multiple frames can arrive in one chunk; see `relay--filter's loop).
;; Success (`relay--request-async') and streaming (`relay--request-stream')
;; callbacks are queued here instead and run from a `run-at-time 0' drain,
;; preserving arrival order per connection.
;;
;; The drain must refuse to run while a synchronous `relay--request' is
;; blocked on this same connection: that wait re-enters the event loop via
;; `accept-process-output', which also runs timers, so an ungated drain would
;; let arbitrary application code execute underneath a caller that reasonably
;; assumes nothing else runs during its blocking call. The drain reschedules
;; itself until the blocking request resolves.

(defun relay--conn-has-blocked-waiter-p (conn)
  "Non-nil if some synchronous `relay--request' is still blocked on CONN."
  (let ((blocked nil))
    (maphash (lambda (_id entry) (when (eq entry 'waiting) (setq blocked t)))
             (relay-conn-pending conn))
    blocked))

(defconst relay--blocked-drain-retry-delay 0.05
  "Retry delay for a drain that found a blocked synchronous request.

A blocked `relay--request' can wait up to `relay-request-timeout' (or
`relay-connect-timeout', or an explicit exec TIMEOUT-MS -- tens of seconds).
The condition only changes once that request resolves, so retrying via
`run-at-time 0' would busy-poll an O(pending-count) check as fast as Emacs
can cycle 0-delay timers for the whole wait. This delay is otherwise
invisible: once actually unblocked, the normal path still drains via
`run-at-time 0'.")

(defun relay--drain-callback-queue (conn)
  "Run CONN's queued callbacks in arrival order, unless a synchronous request
is still blocked on CONN, in which case reschedule instead of running any of
them -- see this section's header comment."
  (setf (relay-conn-drain-scheduled conn) nil)
  (when (relay-conn-callback-queue conn)
    (if (relay--conn-has-blocked-waiter-p conn)
        (relay--maybe-schedule-drain conn relay--blocked-drain-retry-delay)
      (let ((thunks (nreverse (relay-conn-callback-queue conn))))
        (setf (relay-conn-callback-queue conn) nil)
        (dolist (thunk thunks) (funcall thunk))))))

(defun relay--maybe-schedule-drain (conn &optional delay)
  "Schedule a drain of CONN's callback queue after DELAY (default 0)
seconds, unless one is already pending."
  (unless (relay-conn-drain-scheduled conn)
    (setf (relay-conn-drain-scheduled conn) t)
    (run-at-time (or delay 0) nil #'relay--drain-callback-queue conn)))

(defun relay--enqueue-callback (conn thunk)
  "Queue THUNK (a zero-arg function) to run outside the process filter."
  (when (>= (length (relay-conn-callback-queue conn))
            relay-callback-queue-max-length)
    (delete-process (relay-conn-process conn))
    (error "relay: callback queue overflow for %s" (relay-conn-authority conn)))
  (push thunk (relay-conn-callback-queue conn))
  (relay--maybe-schedule-drain conn))

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
  "Process filter: accumulate CHUNK, deframe, and dispatch complete messages.

Tracks an OFFSET into the accumulator instead of re-slicing the unread
suffix with `substring' after every individual frame -- a chunk can contain
several frames (large history burst, several small watch events coalesced by
the OS), and the previous approach copied the whole remaining accumulator
once per frame rather than once per filter call."
  (let ((conn (process-get proc 'relay-conn)))
    (setf (relay-conn-acc conn) (concat (relay-conn-acc conn) chunk))
    (let* ((acc (relay-conn-acc conn))
           (total (length acc))
           (offset 0)
           (done nil))
      (while (and (not done) (>= (- total offset) 4))
        (let ((len (logior (aref acc offset)
                            (ash (aref acc (+ offset 1)) 8)
                            (ash (aref acc (+ offset 2)) 16)
                            (ash (aref acc (+ offset 3)) 24))))
          (cond
           ((not (relay--frame-size-allowed-p len))
            ;; The stream cannot safely be resynchronized after an invalid
            ;; announced length.  Drop it rather than retaining its payload.
            (setq offset total done t)
            (delete-process proc))
           ((< (- total offset) (+ 4 len))
            (setq done t))                ; wait for the rest of this frame
           (t
            (let ((payload (substring acc (+ offset 4) (+ offset 4 len))))
              (setq offset (+ offset 4 len))
              (relay--dispatch conn (decode-coding-string payload 'utf-8)))))))
      (setf (relay-conn-acc conn)
            (if (= offset 0) acc (substring acc offset))))))

(defun relay--dispatch (conn json)
  "Parse one JSON message and route it (reply -> pending table, event -> cache).

The pending table holds one of three shapes per id: the symbol `waiting'
\(a blocked synchronous `relay--request'), a function (a single-reply
`relay--request-async' callback), or `(stream CHUNK-FN . DONE-FN)' (a
multi-reply `relay--request-stream'). Only the last is new — the first two
are exactly as before; a streaming reply just doesn't remove the id from the
table until its final (no `:more') message arrives, so a request can now
have any number of replies before completing instead of exactly one.

Routing and pending-table bookkeeping (matching an id, removing it once its
final reply arrives, installing a synchronous reply) all happen inline here,
still synchronous with the process filter -- only actually invoking an
async/stream callback is deferred, via `relay--enqueue-callback' (see the
\"Deferred callback queue\" section above). Event handling (`relay--handle-event',
a distinct, cache-invalidation-only feature Muster doesn't use) is left
inline; only reply and stream callbacks queue."
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
                (relay--enqueue-callback conn (lambda () (funcall (cadr entry) msg)))
              (remhash id (relay-conn-pending conn))
              (relay--enqueue-callback conn (lambda () (funcall (cddr entry) msg)))))
           ((functionp entry)
            ;; Async request: remove it now (a late duplicate/reply for the
            ;; same id must be a no-op), but defer firing its callback.
            (remhash id (relay-conn-pending conn))
            (relay--enqueue-callback conn (lambda () (funcall entry msg))))
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

(defun relay--request-async (conn op args callback &optional timeout)
  "Send OP with ARGS and call CALLBACK with the reply plist when it arrives.
Returns immediately; never blocks Emacs. Used for background prefetch and any
non-interactive-path work. Replies are id-matched, so out-of-order server
replies are fine.

TIMEOUT, if non-nil, is a number of seconds: if no reply arrives within it,
CALLBACK is called once with a synthetic failure and the id is cancelled (see
`relay--cancel-request'), so a real reply arriving later is silently
dropped. Nil (the default) never times out -- this function's original,
unbounded behavior, unchanged for every existing caller."
  (let ((id (cl-incf (relay-conn-next-id conn))))
    (puthash id callback (relay-conn-pending conn))
    (relay--send conn (append (list :id id :op op) args))
    (when timeout
      (run-at-time timeout nil #'relay--timeout-request conn id))
    id))

(defun relay--request-stream (conn op args chunk-fn done-fn &optional timeout)
  "Like `relay--request-async', but OP may reply with any number of chunks
before completing, not just one. CHUNK-FN is called with each intermediate
reply (one carrying `:more'); DONE-FN is called once, with the final reply
\(the one with no `:more'), after which the id is no longer pending. Never
blocks. See `relay--dispatch' for how the pending-table shape distinguishes
this from a plain single-reply async request.

TIMEOUT is as in `relay--request-async': if non-nil and no reply (of either
kind) arrives within it, DONE-FN is called once with a synthetic failure."
  (let ((id (cl-incf (relay-conn-next-id conn))))
    (puthash id (cons 'stream (cons chunk-fn done-fn)) (relay-conn-pending conn))
    (relay--send conn (append (list :id id :op op) args))
    (when timeout
      (run-at-time timeout nil #'relay--timeout-request conn id))
    id))

(defun relay--cancel-request (conn id)
  "Cancel pending request ID on CONN.

A reply arriving afterward for ID is silently dropped, the same as any reply
for an id no longer in CONN's pending table (see `relay--dispatch'), so this
is idempotent: cancelling an unknown, already-completed, or
already-cancelled id is a harmless no-op. Only meaningful for
`relay--request-async'/`relay--request-stream' ids -- a synchronous
`relay--request' blocks its only caller until it resolves, so nothing else
could call this concurrently for its id.

Does not explicitly cancel any timer registered by that request's TIMEOUT:
`relay--timeout-request' already re-checks the pending table before acting,
so a timer that fires after cancellation is itself a harmless no-op: not
worth the bookkeeping of tracking and cancelling timer objects for a case
that is already safe."
  (remhash id (relay-conn-pending conn)))

(defun relay--timeout-request (conn id)
  "Synthesize a timeout failure for ID on CONN, if it is still pending.

A no-op if ID already completed or was cancelled before this fired -- see
`relay--cancel-request'."
  (let ((entry (gethash id (relay-conn-pending conn))))
    (when (or (functionp entry) (and (consp entry) (eq (car entry) 'stream)))
      (remhash id (relay-conn-pending conn))
      (let ((failure (list :ok nil :error "relay: request timed out" :timeout t))
            (fn (if (functionp entry) entry (cddr entry))))
        (relay--enqueue-callback conn (lambda () (funcall fn failure)))))))

;;;; ---------------------------------------------------------------------------
;;;; Async file read primitives

(defun relay-tail-read-async (authority path known-offset known-dev known-ino max-bytes on-success on-error)
  "Read an append-tolerant tail snapshot of PATH on AUTHORITY's server.

Never blocks. Requires the server to advertise `tail-read-v1'; ON-ERROR is
called if it does not.

KNOWN-OFFSET is the byte offset already read (0 for a fresh open).
KNOWN-DEV/KNOWN-INO, if non-nil, are the device/inode this client already
associates with PATH. When the server's current file no longer matches them,
or KNOWN-OFFSET is no longer a valid prefix of the current file's size, the
server re-anchors the read at byte 0 and reports a plist with :truncated-or-
rotated t rather than signaling an error -- callers MUST check that field
and discard any buffered partial state (e.g. an incomplete trailing JSONL
record retained from a previous read) when it is non-nil; the returned bytes
in that case do not continue KNOWN-OFFSET, they start fresh at file offset
0. MAX-BYTES bounds this single reply; check :more-available in the result
to know whether more remains beyond what this call returned.

ON-SUCCESS is called with a plist:
  (:bytes BYTES :start N :actual-end N :file-size N :dev N :ino N
   :truncated-or-rotated BOOL :more-available BOOL)
BYTES is a unibyte string containing the exact bytes returned (already
base64-decoded). ON-ERROR is called with a failure plist for a missing
capability, a connection failure, or the request itself failing.

Returns nil; this is a purely callback-based API."
  (relay-connect-async
   authority
   (lambda (conn)
     ;; Connection is ready; check the tail-read-v1 capability.
     (let ((hello (relay-conn-hello conn)))
       (if (member "tail-read-v1" (plist-get hello :capabilities))
           ;; Has tail-read-v1: build args and send the tail_read request.
           (let* ((args (append (list :path path :known_offset known-offset :max_bytes max-bytes)
                                (when known-dev (list :known_dev known-dev))
                                (when known-ino (list :known_ino known-ino)))))
             ;; Send the tail_read request and handle the reply.
             (relay--request-async
              conn "tail_read" args
              (lambda (reply)
                (if (plist-get reply :ok)
                    ;; Success: build the result plist and call on-success.
                    (funcall on-success
                             (list :bytes (base64-decode-string (or (plist-get reply :bytes_b64) ""))
                                   :start (plist-get reply :start)
                                   :actual-end (plist-get reply :actual_end)
                                   :file-size (plist-get reply :file_size)
                                   :dev (plist-get reply :dev)
                                   :ino (plist-get reply :ino)
                                   :truncated-or-rotated (plist-get reply :truncated_or_rotated)
                                   :more-available (plist-get reply :more_available)))
                  ;; Request failed: call on-error.
                  (funcall on-error (list :ok nil :error (plist-get reply :error)))))))
         ;; Missing tail-read-v1 capability: call on-error asynchronously.
         (run-at-time 0 nil on-error
                      (list :ok nil
                            :error (format "relay-tail-read-async: server for %s does not support tail-read (capabilities: %S) -- rebuild/reinstall relay-server via scripts/install-server.sh"
                                           authority (plist-get hello :capabilities)))))))
   ;; If relay-connect-async's on-error fires (connection failed), call our on-error.
   (lambda (failure)
     (funcall on-error failure)))
  nil)

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
            (relay--require-revision-capability (relay-conn-hello conn))
            (setf (relay-conn-ready conn) t))
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
      ;; Same reasoning for direct file-notify watches (dired, auto-revert):
      ;; see `relay--rewatch-direct-on-connect'.
      (relay--rewatch-direct-on-connect conn)
      conn)))

;;;; ---------------------------------------------------------------------------
;;;; Async connection establishment

(defun relay-connect-async (authority on-ready on-error)
  "Ensure a ready connection for AUTHORITY, calling ON-READY with it.

Fans concurrent callers for the same not-yet-ready connection out to a
single in-flight connect attempt rather than starting a redundant one.
ON-READY/ON-ERROR are always called asynchronously (never from within this
call), even when a ready connection already exists, so callers cannot
observe two different calling conventions depending on connection state.
Returns nil; this is a purely callback-based API, there is nothing
meaningful to return synchronously (see README-LATENCY.md's guidance
against local methods returning data synchronously)."
  (let ((conn (gethash authority relay--connections)))
    (cond
     ((and conn (process-live-p (relay-conn-process conn)) (relay-conn-ready conn))
      ;; Ready connection exists: call on-ready asynchronously with it.
      (run-at-time 0 nil on-ready conn))
     ((and conn (process-live-p (relay-conn-process conn)))
      ;; Connection exists but not ready yet: queue this waiter to be called when ready.
      (push (cons on-ready on-error) (relay-conn-connect-waiters conn)))
     (t
      ;; No connection: start a fresh async connect with this waiter.
      (relay--connect-async-start authority (list (cons on-ready on-error)))))
    nil))

(defun relay--connect-async-start (authority waiters)
  "Start an async connection for AUTHORITY, queuing WAITERS for notification.

WAITERS is a list of (on-ready . on-error) pairs."
  (let* ((default-directory temporary-file-directory)
         (stderr (get-buffer-create (format " *relay-%s-stderr*" authority)))
         proc conn)
    (with-current-buffer stderr
      (let ((inhibit-read-only t)) (erase-buffer)))
    (condition-case err
        (let ((cmd (relay--auth-command authority)))
          (setq proc (make-process
                      :name (format "relay-%s" authority)
                      :command cmd
                      :coding 'binary
                      :connection-type 'pipe
                      :noquery t
                      :stderr stderr
                      :filter #'relay--filter
                      :sentinel #'relay--sentinel))
          (setq conn (relay--make-conn :process proc :authority authority
                                       :connect-waiters waiters))
          (process-put proc 'relay-conn conn)
          (process-put proc 'relay-stderr-buffer stderr)
          (puthash authority conn relay--connections)
          ;; Send hello asynchronously with a callback to handle the reply.
          (relay--request-async conn "hello" (list :version relay-protocol-version)
                                (lambda (reply)
                                  (relay--connect-async-hello-done conn reply))
                                relay-connect-timeout))
      (error
       ;; On any synchronous error (auth-command fail, make-process fail, send
       ;; fail), undo any partial setup -- matching the synchronous
       ;; `relay--connect's cleanup -- before notifying waiters, so a broken
       ;; half-registered conn can never linger in `relay--connections'.
       (when (and conn (eq (gethash authority relay--connections) conn))
         (remhash authority relay--connections))
       (when (and proc (process-live-p proc))
         (delete-process proc))
       (let ((failure (list :ok nil :error (error-message-string err))))
         (dolist (waiter waiters)
           (when (cdr waiter)
             (run-at-time 0 nil (cdr waiter) failure))))))))

(defun relay--connect-async-hello-done (conn reply)
  "Handle the hello reply for an async connection attempt.

Either completes the connection successfully and calls all waiters' on-ready
callbacks, or calls all waiters' on-error callbacks if the hello failed."
  (let ((waiters (nreverse (relay-conn-connect-waiters conn)))
        (authority (relay-conn-authority conn)))
    ;; Clear the waiters list now that we've captured it.
    (setf (relay-conn-connect-waiters conn) nil)
    ;; Check for failure: either the reply is not ok, or protocol checks fail.
    (let ((hello-error nil))
      (cond
       ((not (plist-get reply :ok))
        ;; Request failed (timeout, transport error, etc).
        (setq hello-error reply))
       (t
        ;; Request succeeded; now check protocol and capabilities.
        (condition-case err
            (progn
              (relay--require-protocol-version reply)
              (relay--require-revision-capability reply))
          (error
           ;; Protocol check failed.
           (setq hello-error (list :ok nil :error (error-message-string err)))))))
      (if hello-error
          ;; Failed: remove the connection and call each waiter's on-error.
          (progn
            (when (eq (gethash authority relay--connections) conn)
              (remhash authority relay--connections))
            (when (process-live-p (relay-conn-process conn))
              (delete-process (relay-conn-process conn)))
            (dolist (waiter waiters)
              (when (cdr waiter)
                (run-at-time 0 nil (cdr waiter) hello-error))))
        ;; Success: set hello, mark ready, revalidate, and call each waiter's on-ready.
        (setf (relay-conn-hello conn) reply)
        (setf (relay-conn-ready conn) t)
        (relay--revalidate-marked-on-connect conn)
        (relay--rewatch-direct-on-connect conn)
        (dolist (waiter waiters)
          (when (car waiter)
            (run-at-time 0 nil (car waiter) conn)))))))

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

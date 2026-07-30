;;; relay-exec.el --- Synchronous remote command execution for relay -*- lexical-binding: t; -*-

;; A small, deliberately limited primitive: run one argv command on the
;; server side, block until it exits (or times out), and return its exit
;; code plus captured stdout/stderr.  This is NOT `process-file'/
;; `start-file-process' file-name-handler support (no streaming stdin/stdout,
;; no async sentinels, no long-running interactive processes) -- that is a
;; later, larger milestone.  `relay-exec-raw' never builds a shell string: COMMAND
;; is always sent as an argv list and the server never interprets it through
;; a shell either.

;;; Code:

(require 'relay-core)

(defun relay--exec-validate-command (command)
  "Signal an error unless COMMAND is a non-empty list of strings."
  (cond
   ((null command)
    (error "relay-exec-raw: COMMAND must not be empty"))
   ((not (and (listp command) (seq-every-p #'stringp command)))
    (error "relay-exec-raw: COMMAND must be a list of strings, got %S" command))))

(defun relay--exec-validate-options (cwd timeout-ms)
  "Signal an error for malformed CWD or TIMEOUT-MS."
  (when (and cwd (not (stringp cwd)))
    (error "relay-exec-raw: CWD must be a string, got %S" cwd))
  (when (and timeout-ms
             (not (and (integerp timeout-ms) (> timeout-ms 0))))
    (error "relay-exec-raw: TIMEOUT-MS must be a positive integer, got %S"
           timeout-ms)))

(defun relay-exec-raw (authority command &optional cwd timeout-ms)
  "Run COMMAND on the relay server for AUTHORITY; block until it completes.

AUTHORITY is a connection string like \"ssh+HOST\" or \"local\" (see
`relay--connection'). COMMAND is a list of strings: the program name first,
then its arguments, exactly as passed to `call-process' -- never a shell
string, and never interpreted by a shell on either end. CWD, if non-nil, is
the remote directory to run COMMAND in (server default: its own working
directory). TIMEOUT-MS, if non-nil, overrides the server's own default
timeout for how long COMMAND may run before being killed; the client's own
blocking wait is extended to accommodate it (see below), so a large
TIMEOUT-MS does not make this call return early with a generic client-side
timeout instead of the server's own clear \"timed out\" error. If TIMEOUT-MS
is nil, the request omits that key entirely so the server's own default
applies (currently 30s); the client allows a small cushion for that default.

Returns a plist `(:exit-code N :stdout BYTES :stderr BYTES)' on success,
where BYTES are unibyte strings containing the exact captured bytes, and N is
nil if COMMAND was terminated by a signal rather than exiting
normally (see `process-exit-status'/`call-process' for the same shape).
Signals an error if COMMAND is invalid, if the connected server predates
this capability, or (via `relay-request-error', same as any other relay
request) if the request itself fails."
  (relay--exec-validate-command command)
  (relay--exec-validate-options cwd timeout-ms)
  (let* ((conn (relay--connection authority))
         (hello (relay-conn-hello conn)))
    (unless (member "exec-v1" (plist-get hello :capabilities))
      (error "relay-exec-raw: server for %s does not support exec (capabilities: %S) -- rebuild/reinstall relay-server via scripts/install-server.sh"
             authority (plist-get hello :capabilities)))
    (let* (;; `json-serialize' treats a plain Lisp list as a candidate
           ;; JSON *object* (alist/plist), not an array -- only a vector
           ;; serializes as a JSON array. COMMAND is validated as a list
           ;; above (the natural Elisp shape, matching `call-process' and
           ;; this codebase's own argv-list convention), so convert it
           ;; here, at the wire boundary, rather than asking callers to
           ;; pass a vector.
           (args (append (list :command (vconcat command))
                          (when cwd (list :cwd cwd))
                          (when timeout-ms (list :timeout_ms timeout-ms))))
           ;; The server's own timeout error is only observable here if
           ;; this call's blocking wait outlasts it. Only widen the wait
           ;; when TIMEOUT-MS is explicit -- when it's nil we deliberately
           ;; do not duplicate the server's own default value client-side
           ;; (see the docstring), so this just uses `relay-request-timeout'
           ;; as-is, same as every other request.  The server default is
           ;; 30s, so provide a small cushion even when TIMEOUT-MS is nil.
           (relay-request-timeout
            (if timeout-ms
                (+ 2.0 (/ timeout-ms 1000.0))
              (max relay-request-timeout 32.0)))
           (reply
            (condition-case err
                (apply #'relay--request conn "exec" args)
              (quit
               (relay--exec-abort-connection conn)
               (signal (car err) (cdr err)))
              (error
               (when (string-match-p "\\(timed out\\|transport\\|connection\\)"
                                     (error-message-string err))
                 (relay--exec-abort-connection conn))
               (signal (car err) (cdr err))))))
      (list :exit-code (plist-get reply :exit_code)
            :stdout (base64-decode-string (or (plist-get reply :stdout_b64) ""))
            :stderr (base64-decode-string (or (plist-get reply :stderr_b64) ""))))))

(defun relay--exec-abort-connection (conn)
  "Close CONN so a server-side exec is cancelled after a client abort."
  (let ((proc (relay-conn-process conn)))
    (when (process-live-p proc)
      (delete-process proc))
    (when (eq (gethash (relay-conn-authority conn) relay--connections) conn)
      (remhash (relay-conn-authority conn) relay--connections)))
  nil)

(defun relay-exec-text (authority command &optional cwd timeout-ms)
  "Run COMMAND and decode its stdout and stderr as UTF-8 text.

This is the text-oriented convenience wrapper around `relay-exec-raw'."
  (let ((result (relay-exec-raw authority command cwd timeout-ms)))
    (list :exit-code (plist-get result :exit-code)
          :stdout (decode-coding-string (plist-get result :stdout) 'utf-8)
          :stderr (decode-coding-string (plist-get result :stderr) 'utf-8))))

;;;; ---------------------------------------------------------------------------
;;;; Async command execution

(defun relay-exec-raw-async (authority command on-success on-error &optional cwd timeout-ms)
  "Async counterpart to `relay-exec-raw'. Never blocks.

ON-SUCCESS is called with the same plist `relay-exec-raw' returns:
`(:exit-code N :stdout BYTES :stderr BYTES)'. ON-ERROR is called
asynchronously with a failure plist for a connection failure, a missing
exec-v1 capability, or the request itself failing. COMMAND/CWD/TIMEOUT-MS
are still validated synchronously and signal an ordinary Lisp error
immediately, exactly like `relay-exec-raw' -- ON-ERROR is never called for
that case, only for failures reached after this function has already
returned.

Returns nil; this is a purely callback-based API."
  ;; Validate COMMAND/CWD/TIMEOUT-MS synchronously up front.
  ;; These can signal, but they're pure argument checks (no async contract violation).
  (relay--exec-validate-command command)
  (relay--exec-validate-options cwd timeout-ms)

  ;; Use relay-connect-async to get a ready connection, then send the exec request.
  (relay-connect-async
   authority
   (lambda (conn)
     ;; Connection is ready; check the exec-v1 capability.
     (let ((hello (relay-conn-hello conn)))
       (if (member "exec-v1" (plist-get hello :capabilities))
           ;; Has exec-v1: build args and send the exec request.
           (let* ((args (append (list :command (vconcat command))
                                (when cwd (list :cwd cwd))
                                (when timeout-ms (list :timeout_ms timeout-ms))))
                  ;; Calculate the timeout for relay--request-async: add 2s cushion
                  ;; to the server timeout, or nil if no explicit timeout-ms.
                  (req-timeout (and timeout-ms (+ 2.0 (/ timeout-ms 1000.0)))))
             ;; Send the exec request and handle the reply.
             (relay--request-async
              conn "exec" args
              (lambda (reply)
                (if (plist-get reply :ok)
                    ;; Success: build the result plist and call on-success.
                    (funcall on-success
                             (list :exit-code (plist-get reply :exit_code)
                                   :stdout (base64-decode-string (or (plist-get reply :stdout_b64) ""))
                                   :stderr (base64-decode-string (or (plist-get reply :stderr_b64) ""))))
                  ;; Request failed: normalize error to plist and call on-error.
                  (funcall on-error (list :ok nil :error (plist-get reply :error)))))
              req-timeout))
         ;; Missing exec-v1 capability: call on-error asynchronously.
         (run-at-time 0 nil on-error
                      (list :ok nil
                            :error (format "relay-exec-raw-async: server for %s does not support exec (capabilities: %S) -- rebuild/reinstall relay-server via scripts/install-server.sh"
                                           authority (plist-get hello :capabilities)))))))
   ;; If relay-connect-async's on-error fires (connection failed), call our on-error.
   (lambda (failure)
     (funcall on-error failure)))
  nil)

(defun relay-exec-text-async (authority command on-success on-error &optional cwd timeout-ms)
  "Async counterpart to `relay-exec-text' -- decodes stdout/stderr as UTF-8.

Text-oriented convenience wrapper around `relay-exec-raw-async'.
ON-SUCCESS is called with a plist whose :stdout and :stderr are decoded as UTF-8.
ON-ERROR is called if any error occurs (see `relay-exec-raw-async')."
  (relay-exec-raw-async
   authority command
   (lambda (result)
     ;; Decode stdout/stderr as UTF-8 and call on-success with the text result.
     (funcall on-success
              (list :exit-code (plist-get result :exit-code)
                    :stdout (decode-coding-string (plist-get result :stdout) 'utf-8)
                    :stderr (decode-coding-string (plist-get result :stderr) 'utf-8))))
   on-error
   cwd timeout-ms)
  nil)

(provide 'relay-exec)
;;; relay-exec.el ends here

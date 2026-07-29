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

(provide 'relay-exec)
;;; relay-exec.el ends here

;;; relay-exec.el --- Synchronous remote command execution for relay -*- lexical-binding: t; -*-

;; A small, deliberately limited primitive: run one argv command on the
;; server side, block until it exits (or times out), and return its exit
;; code plus captured stdout/stderr.  This is NOT `process-file'/
;; `start-file-process' file-name-handler support (no streaming stdin/stdout,
;; no async sentinels, no long-running interactive processes) -- that is a
;; later, larger milestone.  `relay-exec' never builds a shell string: COMMAND
;; is always sent as an argv list and the server never interprets it through
;; a shell either.

;;; Code:

(require 'relay-core)

(defun relay--exec-validate-command (command)
  "Signal an error unless COMMAND is a non-empty list of strings."
  (cond
   ((null command)
    (error "relay-exec: COMMAND must not be empty"))
   ((not (and (listp command) (seq-every-p #'stringp command)))
    (error "relay-exec: COMMAND must be a list of strings, got %S" command))))

(defun relay-exec (authority command &optional cwd timeout-ms)
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
applies (currently also 30s, i.e. equal to `relay-request-timeout's own
default) -- this call then simply uses `relay-request-timeout' unmodified,
same as every other relay request.

Returns a plist `(:exit-code N :stdout STRING :stderr STRING)' on success,
where N is nil if COMMAND was terminated by a signal rather than exiting
normally (see `process-exit-status'/`call-process' for the same shape).
Signals an error if COMMAND is invalid, if the connected server predates
this capability, or (via `relay-request-error', same as any other relay
request) if the request itself fails."
  (relay--exec-validate-command command)
  (let* ((conn (relay--connection authority))
         (hello (relay-conn-hello conn)))
    (unless (member "exec-v1" (plist-get hello :capabilities))
      (error "relay-exec: server for %s does not support exec (capabilities: %S) -- rebuild/reinstall relay-server via scripts/install-server.sh"
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
           ;; as-is, same as every other request.
           (relay-request-timeout
            (if timeout-ms
                (+ 2.0 (/ timeout-ms 1000.0))
              relay-request-timeout))
           (reply (apply #'relay--request conn "exec" args)))
      (list :exit-code (plist-get reply :exit_code)
            :stdout (decode-coding-string
                     (base64-decode-string (or (plist-get reply :stdout_b64) ""))
                     'utf-8)
            :stderr (decode-coding-string
                     (base64-decode-string (or (plist-get reply :stderr_b64) ""))
                     'utf-8)))))

(provide 'relay-exec)
;;; relay-exec.el ends here

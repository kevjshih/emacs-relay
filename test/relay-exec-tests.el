;;; relay-exec-tests.el --- Regression tests for relay-exec -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst relay-exec-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(load-file (expand-file-name "lisp/relay.el" relay-exec-test--root))

;; Same convention as `relay-tests.el': the `local' transport spawns this
;; binary directly (no ssh) as relay's own portable, no-network way to
;; exercise the real RPC round trip. Build it first: `cd server && cargo
;; build'.
(defconst relay-exec-test--server-path
  (expand-file-name "server/target/debug/relay-server" relay-exec-test--root))

(defun relay-exec-test--conn ()
  "A bare `relay-conn' for no-wire unit tests (mirrors `relay-test--conn' in
relay-tests.el)."
  (relay--make-conn
   :authority "local"
   :pending (make-hash-table)
   :dircache (make-hash-table :test 'equal)
   :dircache-mtime (make-hash-table :test 'equal)
   :watches (make-hash-table :test 'equal)))

(defun relay-exec-test--hash-values (table)
  (let (values)
    (maphash (lambda (_ value) (push value values)) table)
    values))

(defmacro relay-exec-test--with-local-conn (conn-var &rest body)
  "Bind CONN-VAR to a fresh real `local'-transport connection for BODY, then
tear down every connection it opened (killing the server subprocess) even
if BODY errors."
  (declare (indent 1))
  `(let* ((relay--connections (make-hash-table :test 'equal))
          (relay-server-local-path relay-exec-test--server-path)
          (,conn-var (relay--connection "local")))
     (unwind-protect
         (progn ,@body)
       (dolist (c (relay-exec-test--hash-values relay--connections))
         (when (process-live-p (relay-conn-process c))
           (delete-process (relay-conn-process c)))))))

;;;; ---------------------------------------------------------------------------
;;;; Real integration tests, over the local transport (genuine subprocess
;;;; execution on the server side, not mocked).

(ert-deftest relay-exec-runs-a-command-and-returns-its-stdout ()
  "A successful command reports exit code 0 and its stdout."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec "local" '("echo" "hello-from-relay-exec"))))
      (should (equal (plist-get result :exit-code) 0))
      (should (string-match-p "hello-from-relay-exec" (plist-get result :stdout))))))

(ert-deftest relay-exec-reports-a-nonzero-exit-code ()
  "A command that exits nonzero is reported faithfully, not turned into a
Lisp error -- callers need the real exit code (e.g. to distinguish `grep'
finding nothing from `grep' actually failing)."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec "local" '("sh" "-c" "exit 7"))))
      (should (equal (plist-get result :exit-code) 7)))))

(ert-deftest relay-exec-captures-stdout-and-stderr-separately ()
  "stdout and stderr must not be mixed together in either direction."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec
                   "local" '("sh" "-c" "echo out-text; echo err-text 1>&2"))))
      (should (string-match-p "out-text" (plist-get result :stdout)))
      (should-not (string-match-p "err-text" (plist-get result :stdout)))
      (should (string-match-p "err-text" (plist-get result :stderr)))
      (should-not (string-match-p "out-text" (plist-get result :stderr))))))

;;;; ---------------------------------------------------------------------------
;;;; Client-side validation (no RPC / no server needed).

(ert-deftest relay-exec-rejects-an-empty-command-without-a-round-trip ()
  "Client-side validation must reject before any request is even attempted --
proven here by never establishing a connection at all (`relay--connection'
would error on the bogus \"no-such-authority\" if this ever got that far)."
  (should-error (relay-exec "no-such-authority" nil))
  (should-error (relay-exec "no-such-authority" '(42)))
  (should-error (relay-exec "no-such-authority" "echo hi")))

;;;; ---------------------------------------------------------------------------
;;;; Capability gating -- exercised without any wire I/O, via a bare
;;;; `relay-conn' whose stored hello plist simulates an old server that
;;;; predates `exec-v1' (same no-wire construction pattern `relay-test--conn'
;;;; uses in relay-tests.el, and the same `cl-letf' override of
;;;; `relay--connection' that file already uses throughout for exactly this
;;;; kind of test).

(ert-deftest relay-exec-signals-a-clear-error-when-the-server-lacks-the-capability ()
  "An old, not-yet-rebuilt relay-server must fail with a specific, actionable
message -- not a confusing low-level \"unknown fs op: exec\" surfaced from
deep inside the server, and never a hang."
  (let ((conn (relay-exec-test--conn)))
    (setf (relay-conn-hello conn)
          (list :server_version "0.0.1" :protocol_version 1
                :capabilities '("revisions-v1")))
    (cl-letf (((symbol-function 'relay--connection) (lambda (&rest _) conn))
              ((symbol-function 'relay--request)
               (lambda (&rest _) (ert-fail "must not send a request without exec-v1"))))
      (let ((err (should-error (relay-exec "local" '("echo" "hi")))))
        (should (string-match-p "does not support exec" (error-message-string err)))))))

(ert-deftest relay-exec-proceeds-when-the-server-advertises-the-capability ()
  "The inverse of the above: a hello plist that DOES include exec-v1 must not
be rejected client-side (the request itself is mocked so this stays a
no-wire unit test)."
  (let ((conn (relay-exec-test--conn)) captured)
    (setf (relay-conn-hello conn)
          (list :server_version "0.0.1" :protocol_version 1
                :capabilities '("revisions-v1" "exec-v1")))
    (cl-letf (((symbol-function 'relay--connection) (lambda (&rest _) conn))
              ((symbol-function 'relay--request)
               (lambda (_conn _op &rest args)
                 (setq captured args)
                 (list :ok t :exit_code 0 :stdout_b64 "" :stderr_b64 ""))))
      (relay-exec "local" '("echo" "hi"))
      ;; Sent as a vector, not a list: `json-serialize' treats a plain Lisp
      ;; list as a candidate JSON object, so `relay-exec' converts COMMAND
      ;; at the wire boundary (see its own comment) -- this assertion is
      ;; what actually caught that bug during development.
      (should (equal (plist-get captured :command) ["echo" "hi"]))
      ;; TIMEOUT-MS omitted client-side -> the key itself must be absent so
      ;; the server's own default applies, not merely nil.
      (should-not (plist-member captured :timeout_ms)))))

(ert-deftest relay-exec-widens-the-client-wait-to-fit-an-explicit-timeout-ms ()
  "An explicit TIMEOUT-MS above the ordinary `relay-request-timeout' must not
make `relay-exec' give up client-side before the server's own \"timed out\"
error could possibly come back -- otherwise the caller only ever sees a
generic client timeout and the server's specific message is unreachable."
  (let ((conn (relay-exec-test--conn)) captured-timeout)
    (setf (relay-conn-hello conn)
          (list :protocol_version 1 :capabilities '("exec-v1")))
    (cl-letf (((symbol-function 'relay--connection) (lambda (&rest _) conn))
              ((symbol-function 'relay--request)
               (lambda (&rest _)
                 (setq captured-timeout relay-request-timeout)
                 (list :ok t :exit_code 0 :stdout_b64 "" :stderr_b64 ""))))
      (let ((relay-request-timeout 30.0))
        (relay-exec "local" '("echo" "hi") nil 60000)
        (should (= captured-timeout 62.0))))))

;;;; ---------------------------------------------------------------------------
;;;; Real end-to-end timeout, kept fast per the task's own guidance (a very
;;;; small TIMEOUT-MS rather than a real multi-second sleep/timeout test).

(ert-deftest relay-exec-surfaces-the-servers-timeout-error ()
  "A command that outlives an explicit short TIMEOUT-MS must fail with the
server's own clear timeout error -- proving the widened client-side wait
(see the unit test above) actually lets that error through end-to-end,
rather than the call hanging or a generic client timeout firing first."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((err (should-error (relay-exec "local" '("sleep" "5") nil 300))))
      (should (string-match-p "timed out" (error-message-string err))))))

(provide 'relay-exec-tests)
;;; relay-exec-tests.el ends here

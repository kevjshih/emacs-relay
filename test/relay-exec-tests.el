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
   :dircache-mtime (make-hash-table :test 'equal)))

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
    (let ((result (relay-exec-text "local" '("echo" "hello-from-relay-exec"))))
      (should (equal (plist-get result :exit-code) 0))
      (should (string-match-p "hello-from-relay-exec" (plist-get result :stdout))))))

(ert-deftest relay-exec-reports-a-nonzero-exit-code ()
  "A command that exits nonzero is reported faithfully, not turned into a
Lisp error -- callers need the real exit code (e.g. to distinguish `grep'
finding nothing from `grep' actually failing)."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec-raw "local" '("sh" "-c" "exit 7"))))
      (should (equal (plist-get result :exit-code) 7)))))

(ert-deftest relay-exec-captures-stdout-and-stderr-separately ()
  "stdout and stderr must not be mixed together in either direction."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec-text
                   "local" '("sh" "-c" "echo out-text; echo err-text 1>&2"))))
      (should (string-match-p "out-text" (plist-get result :stdout)))
      (should-not (string-match-p "err-text" (plist-get result :stdout)))
      (should (string-match-p "err-text" (plist-get result :stderr)))
      (should-not (string-match-p "out-text" (plist-get result :stderr))))))

(ert-deftest relay-exec-raw-preserves-non-utf8-bytes ()
  "The raw API returns exact unibyte output without text conversion."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec-raw "local" '("sh" "-c" "printf '\\377'"))))
      (should (= (length (plist-get result :stdout)) 1))
      (should (= (aref (plist-get result :stdout) 0) 255)))))

(ert-deftest relay-exec-text-decodes-utf8-output ()
  "The text API is an explicit UTF-8 convenience layer."
  (relay-exec-test--with-local-conn conn
    (ignore conn)
    (let ((result (relay-exec-text "local" '("printf" "hello"))))
      (should (equal (plist-get result :stdout) "hello")))))

;;;; ---------------------------------------------------------------------------
;;;; Client-side validation (no RPC / no server needed).

(ert-deftest relay-exec-rejects-an-empty-command-without-a-round-trip ()
  "Client-side validation must reject before any request is even attempted --
proven here by never establishing a connection at all (`relay--connection'
would error on the bogus \"no-such-authority\" if this ever got that far)."
  (should-error (relay-exec-raw "no-such-authority" nil))
  (should-error (relay-exec-raw "no-such-authority" '(42)))
  (should-error (relay-exec-raw "no-such-authority" "echo hi")))

(ert-deftest relay-exec-rejects-invalid-options-without-a-round-trip ()
  (should-error (relay-exec-raw "no-such-authority" '("true") nil 0))
  (should-error (relay-exec-raw "no-such-authority" '("true") nil -1))
  (should-error (relay-exec-raw "no-such-authority" '("true") 7)))

(ert-deftest relay-exec-abort-closes-the-connection-and-removes-it ()
  "A client-side abort must close the transport used by the server exec."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (conn (relay-exec-test--conn))
         (proc (start-process "relay-exec-abort-test" nil "sleep" "10")))
    (setf (relay-conn-process conn) proc)
    (puthash "local" conn relay--connections)
    (unwind-protect
        (progn
          (relay--exec-abort-connection conn)
          (should-not (process-live-p proc))
          (should-not (gethash "local" relay--connections)))
      (when (process-live-p proc)
        (delete-process proc)))))

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
      (let ((err (should-error (relay-exec-raw "local" '("echo" "hi")))))
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
      (relay-exec-raw "local" '("echo" "hi"))
      ;; Sent as a vector, not a list: `json-serialize' treats a plain Lisp
      ;; list as a candidate JSON object, so `relay-exec-raw' converts COMMAND
      ;; at the wire boundary (see its own comment) -- this assertion is
      ;; what actually caught that bug during development.
      (should (equal (plist-get captured :command) ["echo" "hi"]))
      ;; TIMEOUT-MS omitted client-side -> the key itself must be absent so
      ;; the server's own default applies, not merely nil.
      (should-not (plist-member captured :timeout_ms)))))

(ert-deftest relay-exec-widens-the-client-wait-to-fit-an-explicit-timeout-ms ()
  "An explicit TIMEOUT-MS above the ordinary `relay-request-timeout' must not
make `relay-exec-raw' give up client-side before the server's own \"timed out\"
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
        (relay-exec-raw "local" '("echo" "hi") nil 60000)
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
    (let ((err (should-error (relay-exec-raw "local" '("sleep" "5") nil 300))))
      (should (string-match-p "timed out" (error-message-string err))))))

;;;; ---------------------------------------------------------------------------
;;;; Async command execution

(ert-deftest relay-exec-raw-async-runs-a-command-and-returns-its-result ()
  "An async command execution against the real server returns the same result
shape as the synchronous version."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path relay-exec-test--server-path)
         (done nil)
         (result nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (relay-exec-raw-async "local"
                                '("echo" "hello-from-async")
                                (lambda (res) (setq result res done t))
                                (lambda (_err) (setq done t)))
          ;; Wait for the callback to fire.
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should result)
          (should (= (plist-get result :exit-code) 0))
          (should (string-match-p "hello-from-async" (plist-get result :stdout))))
      ;; Cleanup
      (dolist (c (relay-exec-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

(ert-deftest relay-exec-raw-async-rejects-an-empty-command-without-async-roundtrip ()
  "Client-side validation (COMMAND validation) must signal synchronously,
not go through on-error asynchronously."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (error-fired nil))
    ;; This should signal synchronously, never calling on-error later.
    (should-error (relay-exec-raw-async "no-such-authority"
                                         nil
                                         (lambda (_res) nil)
                                         (lambda (_err) (setq error-fired t))))
    ;; Give timers a chance to run if the function were broken.
    (sleep-for 0.05)
    (should-not error-fired)))

(ert-deftest relay-exec-raw-async-calls-on-error-when-exec-v1-missing ()
  "If the server lacks exec-v1, on-error is called asynchronously (after
connecting succeeds)."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (conn (relay-exec-test--conn))
         (proc (start-process "relay-exec-test-no-exec" nil "sleep" "10"))
         (done nil)
         (error-result nil)
         (deadline (+ (float-time) 1.0)))
    (unwind-protect
        (progn
          (setf (relay-conn-process conn) proc)
          (setf (relay-conn-hello conn)
                (list :server_version "0.0.1" :protocol_version 1
                      :capabilities '("revisions-v1")))
          (setf (relay-conn-ready conn) t)
          (puthash "test-no-exec" conn relay--connections)
          (relay-exec-raw-async "test-no-exec"
                                '("echo" "hi")
                                (lambda (_res) (setq done t))
                                (lambda (err) (setq error-result err done t)))
          ;; Wait for the callback to fire.
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should error-result)
          (should (string-match-p "does not support exec" (plist-get error-result :error))))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest relay-exec-text-async-decodes-utf8-output ()
  "The async text API decodes stdout/stderr as UTF-8, same as the sync version."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path relay-exec-test--server-path)
         (done nil)
         (result nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (relay-exec-text-async "local"
                                 '("printf" "hello")
                                 (lambda (res) (setq result res done t))
                                 (lambda (_err) (setq done t)))
          ;; Wait for the callback to fire.
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should result)
          (should (equal (plist-get result :stdout) "hello")))
      ;; Cleanup
      (dolist (c (relay-exec-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

(provide 'relay-exec-tests)
;;; relay-exec-tests.el ends here

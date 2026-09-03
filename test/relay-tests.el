;;; relay-tests.el --- Regression tests for relay -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defvar auto-revert-remote-files)

(defconst relay-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(load-file (expand-file-name "lisp/relay.el" relay-test--root))

(defun relay-test--conn (&optional authority)
  (relay--make-conn
   :authority (or authority "local")
   :pending (make-hash-table)
   :dircache (make-hash-table :test 'equal)
   :dircache-mtime (make-hash-table :test 'equal)))

(defun relay-test--hash-values (table)
  (let (values)
    (maphash (lambda (_ value) (push value values)) table)
    values))

(defmacro relay-test--with-clean-global-caches (&rest body)
  `(let ((relay--content-cache (make-hash-table :test 'equal))
         (relay--content-cache-order nil)
         (relay--connections (make-hash-table :test 'equal))
         (relay--listing-prefetch-cache (make-hash-table :test 'equal))
         (relay--listing-prefetch-dirs (make-hash-table :test 'equal))
         (relay--content-prefetch-dirs (make-hash-table :test 'equal))
         (relay--prefetch-profiles (make-hash-table :test 'equal))
         (relay--prefetch-problems (make-hash-table :test 'equal))
         (relay--prefetch-active-profiles '("default"))
         (relay--prefetch-selected-profile "default")
         (relay--ssh-host-cache :uninitialized)
         (relay-listing-prefetch nil)
         (relay-content-prefetch nil))
     ,@body))

(ert-deftest relay-prefetch-load-migrates-the-legacy-global-config ()
  "Legacy marks load as the active `default' profile without data loss."
  (let ((config (make-temp-file "relay-legacy-profile-")))
    (unwind-protect
        (progn
          (with-temp-file config
            (prin1 '(:listing (("ssh+host" . "/work"))
                     :content (("ssh+host" . "/work/src")))
                   (current-buffer)))
          (relay-test--with-clean-global-caches
           (let ((relay-prefetch-config-file config))
             (relay--prefetch-config-load)
             (should (equal relay--prefetch-active-profiles '("default")))
             (should (relay--listing-prefetch-marked-p "ssh+host" "/work"))
             (should (relay--content-prefetch-marked-p "ssh+host" "/work/src"))
             (should (equal (plist-get (relay--prefetch-profile "default") :content)
                            '(("ssh+host" . "/work/src")))))))
      (delete-file config))))

(ert-deftest relay-prefetch-load-tolerates-an-empty-config-file ()
  "An interrupted first save must behave like a fresh profile configuration."
  (let ((config (make-temp-file "relay-empty-profile-")))
    (unwind-protect
        (relay-test--with-clean-global-caches
         (let ((relay-prefetch-config-file config))
           (relay--prefetch-config-load)
           (should (relay--prefetch-profile "default"))
           (should (equal relay--prefetch-active-profiles '("default")))))
      (delete-file config))))

(ert-deftest relay-prefetch-profiles-persist-and-switch-without-cache-leaks ()
  "Switching profiles replaces live marks and evicts prior profile cache data."
  (let ((config (make-temp-file "relay-profile-switch-")))
    (unwind-protect
        (relay-test--with-clean-global-caches
         (let* ((relay-prefetch-config-file config)
                (alpha (cons "ssh+host" "/project-a"))
                (beta (cons "ssh+host" "/project-b"))
                (conn (relay-test--conn "ssh+host")))
           (relay--prefetch-profile-put
            "alpha" (list :name "alpha" :root "/relay:ssh+host:/project-a"
                          :listing (list alpha) :content (list alpha)))
           (relay--prefetch-profile-put
            "beta" (list :name "beta" :root "/relay:ssh+host:/project-b"
                         :listing (list beta) :content (list beta)))
           (setq relay--prefetch-active-profiles '("alpha")
                 relay--prefetch-selected-profile "alpha")
           (relay--prefetch-rebuild-live-marks)
           (puthash "ssh+host" conn relay--connections)
           (puthash "/project-a" 'cached-directory (relay-conn-dircache conn))
           (puthash alpha 'cached-listing relay--listing-prefetch-cache)
           (relay--content-cache-put "ssh+host" "/project-a/src/a.py" "stale")
           (relay-prefetch-switch-profile "beta")
           (should-not (relay--content-prefetch-marked-p "ssh+host" "/project-a"))
           (should (relay--content-prefetch-marked-p "ssh+host" "/project-b"))
           (should-not (gethash alpha relay--listing-prefetch-cache))
           (should-not (gethash "/project-a" (relay-conn-dircache conn)))
           (should-not (gethash (cons "ssh+host" "/project-a/src/a.py")
                                relay--content-cache))
           ;; A clean reload restores the selected/active profile and its marks.
           (clrhash relay--prefetch-profiles)
           (clrhash relay--listing-prefetch-dirs)
           (clrhash relay--content-prefetch-dirs)
           (setq relay--prefetch-active-profiles nil
                 relay--prefetch-selected-profile nil)
           (relay--prefetch-config-load)
           (should (equal relay--prefetch-active-profiles '("beta")))
           (should (equal relay--prefetch-selected-profile "beta"))
           (should (relay--content-prefetch-marked-p "ssh+host" "/project-b"))
           (relay-prefetch-rename-profile "beta" "renamed")
           (should (equal relay--prefetch-active-profiles '("renamed")))
           (should (relay--content-prefetch-marked-p "ssh+host" "/project-b"))
           (relay-prefetch-delete-profile "renamed")
           (should-not (relay--content-prefetch-marked-p "ssh+host" "/project-b"))))
      (delete-file config))))

(ert-deftest relay-prefetch-switch-keeps-a-missing-folder-as-a-retryable-problem ()
  "A switched-in missing folder remains configured, visible, and retryable."
  (let ((config (make-temp-file "relay-profile-missing-")))
    (unwind-protect
        (relay-test--with-clean-global-caches
         (let* ((relay-prefetch-config-file config)
                (key (cons "ssh+host" "/gone"))
                (conn (relay-test--conn "ssh+host")))
           (relay--prefetch-profile-put
            "missing" (list :name "missing" :listing nil :content (list key)))
           (puthash "ssh+host" conn relay--connections)
           (cl-letf (((symbol-function 'process-live-p) (lambda (&rest _) t))
                     ((symbol-function 'relay--request-async) (lambda (&rest _) 1))
                     ((symbol-function 'relay--readdir-all-async)
                      (lambda (_conn _dir callback)
                        (funcall callback '(:ok nil :error "readdir: no such file")))))
             (relay-prefetch-switch-profile "missing"))
           (should (relay--content-prefetch-marked-p "ssh+host" "/gone"))
           (should (equal (gethash key relay--prefetch-problems)
                          "readdir: no such file"))
           (should (equal (relay-prefetch-profile-problems)
                          (list (cons key "readdir: no such file"))))
           ;; If it is recreated later, explicit retry clears the transient error
           ;; without asking the user to reconstruct the profile.
           (cl-letf (((symbol-function 'process-live-p) (lambda (&rest _) t))
                     ((symbol-function 'relay--request-async) (lambda (&rest _) 1))
                     ((symbol-function 'relay--readdir-all-async)
                      (lambda (_conn _dir callback)
                        (funcall callback
                                 '(:ok t :entries nil :self_attrs (:mtime 1 :mtime_nsec 0))))))
             (relay-prefetch-retry-profile-problems))
           (should-not (relay-prefetch-profile-problems))))
      (delete-file config))))

(ert-deftest relay-prefetch-late-rewarm-reply-cannot-resurrect-switched-away-cache ()
  "An in-flight old-profile listing must be ignored after a profile switch."
  (relay-test--with-clean-global-caches
   (let* ((conn (relay-test--conn "ssh+host"))
          (alpha (cons "ssh+host" "/project-a"))
          (beta (cons "ssh+host" "/project-b"))
          callback async-ops)
     (relay--prefetch-profile-put
      "alpha" (list :name "alpha" :listing (list alpha) :content nil))
     (relay--prefetch-profile-put
      "beta" (list :name "beta" :listing (list beta) :content nil))
     (setq relay--prefetch-active-profiles '("alpha")
           relay--prefetch-selected-profile "alpha")
     (relay--prefetch-rebuild-live-marks)
     (cl-letf (((symbol-function 'relay--readdir-all-async)
                (lambda (_conn _dir done-fn) (setq callback done-fn) 1))
               ((symbol-function 'relay--request-async)
                (lambda (_conn op &rest _) (push op async-ops) 2)))
       (relay--listing-rewarm-async conn "/project-a")
       ;; Model an exclusive switch before the original readdir reply arrives.
       (setq relay--prefetch-active-profiles '("beta")
             relay--prefetch-selected-profile "beta")
       (relay--prefetch-rebuild-live-marks)
       (funcall callback '(:ok t :entries ((:name "old"))
                           :self_attrs (:mtime 1 :mtime_nsec 0))))
     (should-not (gethash "/project-a" (relay-conn-dircache conn)))
     (should-not (member "watch" async-ops)))))

(ert-deftest relay-event-invalidates-an-inflight-rewarm-reply ()
  "A delete/rename event must win over an older asynchronous readdir reply."
  (relay-test--with-clean-global-caches
   (let* ((conn (relay-test--conn "ssh+host"))
          (key (cons "ssh+host" "/project"))
          callback async-ops)
     (relay--prefetch-profile-put
      "project" (list :name "project" :listing (list key) :content nil))
     (setq relay--prefetch-active-profiles '("project")
           relay--prefetch-selected-profile "project")
     (relay--prefetch-rebuild-live-marks)
     (cl-letf (((symbol-function 'relay--readdir-all-async)
                (lambda (_conn _dir done-fn) (setq callback done-fn) 1))
               ((symbol-function 'relay--request-async)
                (lambda (_conn op &rest _) (push op async-ops) 2)))
       (relay--listing-rewarm-async conn "/project")
       ;; This models a deletion/rename event delivered before the response.
       (relay--handle-event conn '(:event "self_changed" :dir "/project"))
       (funcall callback '(:ok t :entries ((:name "stale"))
                           :self_attrs (:mtime 1 :mtime_nsec 0))))
     (should-not (gethash "/project" (relay-conn-dircache conn)))
     (should-not (member "watch" async-ops)))))

(ert-deftest relay-prefetch-dired-mode-decorates-content-marked-folders ()
  "The Dired UI must expose existing content marks without another browser."
  (let* ((root (make-temp-file "relay-prefetch-dired-" t))
         (child (expand-file-name "src" root))
         buffer)
    (unwind-protect
        (progn
          (make-directory child)
          (relay-test--with-clean-global-caches
           (puthash (cons "local" child) t relay--content-prefetch-dirs)
           (setq buffer (dired-noselect root))
           (with-current-buffer buffer
             ;; Dired is local here; model only the parse result so this test
             ;; exercises decoration without starting a remote connection.
             (cl-letf (((symbol-function 'relay--parse)
                        (lambda (path) (cons "local" path))))
               (relay-prefetch-dired-mode 1)
               (should relay-prefetch-dired-mode)
               (should relay--prefetch-dired-overlays)
               (should (eq (car header-line-format) :eval))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest relay-event-removal-evicts-cached-descendants ()
  "Removing a directory must not leave its cached children reachable."
  (relay-test--with-clean-global-caches
   (let ((conn (relay-test--conn)))
     (puthash "/root/a" 'a (relay-conn-dircache conn))
     (puthash "/root/a/b" 'b (relay-conn-dircache conn))
     (puthash "/root/a/b" '(1 . 2) (relay-conn-dircache-mtime conn))
     (relay--content-cache-put "local" "/root/a/b/file.txt" "stale")
     (relay--handle-event conn '(:event "removed" :dir "/root" :name "a"))
     (should-not (gethash "/root/a" (relay-conn-dircache conn)))
     (should-not (gethash "/root/a/b" (relay-conn-dircache conn)))
     (should-not (gethash (cons "local" "/root/a/b/file.txt") relay--content-cache)))))

(ert-deftest relay-self-change-evicts-cached-descendants ()
  "A watched directory renamed/deleted directly must evict its whole subtree."
  (relay-test--with-clean-global-caches
   (let ((conn (relay-test--conn)))
     (puthash "/root/a" 'a (relay-conn-dircache conn))
     (puthash "/root/a/b" 'b (relay-conn-dircache conn))
     (puthash "/root/a/b" '(1 . 2) (relay-conn-dircache-mtime conn))
     (relay--handle-event conn '(:event "self_changed" :dir "/root/a"))
     (should-not (gethash "/root/a" (relay-conn-dircache conn)))
     (should-not (gethash "/root/a/b" (relay-conn-dircache conn)))
     (should-not (gethash "/root/a/b" (relay-conn-dircache-mtime conn))))))

(ert-deftest relay-self-change-notifies-direct-file-watch ()
  "A direct file watch must receive the server's self_changed notification."
  (let* ((relay--direct-watches (make-hash-table :test 'equal))
         (conn (relay-test--conn))
         (path "/root/file.txt")
         received
         (descriptor (relay--direct-watch-add
                      "local" path (lambda (event) (setq received event)))))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_delay _repeat function &rest args) (apply function args))))
      (relay--handle-event conn (list :event "self_changed" :dir path)))
    (should received)
    (should (equal (nth 0 received) descriptor))
    (should (eq (nth 1 received) 'changed))
    (should (equal (nth 2 received) "/relay:local:/root/file.txt"))))

(ert-deftest relay-file-notify-rejects-a-failed-server-watch ()
  "Never return a valid-looking descriptor when the OS watch was rejected."
  (let ((relay--direct-watches (make-hash-table :test 'equal))
        (conn (relay-test--conn)))
    (cl-letf (((symbol-function 'relay--connection) (lambda (_) conn))
              ((symbol-function 'relay--request)
               (lambda (&rest _) (error "watch resources exhausted"))))
      (should-error
       (relay--h-file-notify-add-watch
        "/relay:local:/root/file.txt" '(change) #'ignore))
      (should (= (hash-table-count relay--direct-watches) 0)))))

(ert-deftest relay-visited-modtime-preserves-nanoseconds ()
  "Two edits in the same second must not compare as an unchanged file."
  (let ((nsec 100))
    (with-temp-buffer
      (setq buffer-file-name "/relay:local:/root/file.txt")
      (cl-letf (((symbol-function 'relay--connection) (lambda (&rest _) :conn))
                ((symbol-function 'relay--stat)
                 (lambda (&rest _) (list :mtime 1700000000 :mtime_nsec nsec))))
        (relay--h-set-visited-file-modtime)
        (setq nsec 200)
        (should-not (relay--h-verify-visited-file-modtime (current-buffer)))))))

(ert-deftest relay-write-region-honors-mustbenew ()
  "The write request must retain Emacs's create-only requirement."
  (let ((conn (relay-test--conn)) captured)
    (cl-letf (((symbol-function 'relay--connection) (lambda (&rest _) conn))
              ((symbol-function 'relay--request)
               (lambda (_conn _op &rest args) (setq captured args) '(:ok t))))
      (relay--h-write-region "new" nil "/relay:local:/root/new.txt" nil nil nil t))
    (should (eq (plist-get captured :must_be_new) t))))

(ert-deftest relay-frame-size-limit-rejects-oversized-replies ()
  "The client must not retain a reply larger than its protocol limit."
  (let ((relay-max-frame-bytes 1024))
    (should (relay--frame-size-allowed-p 1024))
    (should-not (relay--frame-size-allowed-p 1025))))

(ert-deftest relay-dead-transport-fails-request-with-stderr-immediately ()
  "A failed SSH process must not leave `hello' waiting for the RPC timeout."
  (let* ((stderr (generate-new-buffer " *relay-dead-transport-stderr*"))
         (proc (make-process
                :name "relay-test-dead-transport"
                :command '("sh" "-c"
                           "head -c 1 >/dev/null; printf 'Permission denied (publickey).\\n' >&2; exit 255")
                :connection-type 'pipe :coding 'binary :noquery t
                :stderr stderr))
         (conn (relay-test--conn "ssh+unreachable"))
         (relay-request-timeout 1.0)
         (started (float-time))
         failure)
    (unwind-protect
        (progn
          (setf (relay-conn-process conn) proc)
          (process-put proc 'relay-conn conn)
          (process-put proc 'relay-stderr-buffer stderr)
          (set-process-sentinel proc #'relay--sentinel)
          (setq failure
                (condition-case err
                    (progn (relay--request conn "hello" :version 1) nil)
                  (error (error-message-string err))))
          (should (< (- (float-time) started) 0.8))
          (should (string-match-p "Permission denied" failure))
          (should-not (gethash 1 (relay-conn-pending conn))))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer stderr))))

(ert-deftest relay-ssh-command-bounds-connection-establishment ()
  "Unreachable SSH destinations get one short, configurable connect attempt."
  (let ((relay-ssh-executable "ssh")
        (relay-ssh-extra-args '("-v"))
        (relay-ssh-connect-timeout 4)
        (relay-server-remote-path "agent"))
    (should (equal (relay--auth-command "ssh+missing")
                   '("ssh" "-v" "-o" "ConnectTimeout=4"
                     "-o" "ConnectionAttempts=1" "missing" "agent")))))

(ert-deftest relay-ssh-connect-timeout-can-defer-to-ssh-config ()
  "A nil timeout preserves the previous fully-config-driven command shape."
  (let ((relay-ssh-executable "ssh")
        (relay-ssh-extra-args nil)
        (relay-ssh-connect-timeout nil)
        (relay-server-remote-path "agent"))
    (should (equal (relay--auth-command "ssh+configured")
                   '("ssh" "configured" "agent")))))

(ert-deftest relay-transport-exit-releases-every-pending-request-shape ()
  "Disconnects release sync, async, and streaming requests exactly once."
  (let* ((conn (relay-test--conn "ssh+gone"))
         (pending (relay-conn-pending conn))
         (failure '(:ok nil :error "gone" :transport t))
         async-result stream-result)
    (puthash 1 'waiting pending)
    (puthash 2 (lambda (reply) (setq async-result reply)) pending)
    (puthash 3 (cons 'stream
                     (cons #'ignore
                           (lambda (reply) (setq stream-result reply))))
             pending)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args)
                 (apply function args))))
      (relay--fail-pending conn failure))
    (should (equal (gethash 1 pending) failure))
    (should-not (gethash 2 pending))
    (should-not (gethash 3 pending))
    (should (equal async-result failure))
    (should (equal stream-result failure))))

(defun relay-test--frame (plist)
  "Return one length-prefixed protocol frame encoding PLIST, matching
`relay--send's wire format, for feeding directly to `relay--filter' in tests."
  (let* ((payload (encode-coding-string (json-serialize plist) 'utf-8))
         (len (length payload)))
    (concat (unibyte-string (logand len #xff)
                            (logand (ash len -8) #xff)
                            (logand (ash len -16) #xff)
                            (logand (ash len -24) #xff))
            payload)))

(ert-deftest relay-async-callback-does-not-run-while-a-sync-request-is-blocked ()
  "A callback queued for CONN while another request on the same CONN is still
`waiting' (a blocked synchronous `relay--request') must not run until that
synchronous request resolves -- otherwise application code would re-enter
Emacs's single Lisp thread underneath the blocked wait (the hazard
`relay--drain-callback-queue's header comment describes)."
  (let* ((conn (relay-test--conn))
         (pending (relay-conn-pending conn))
         (ran nil))
    (puthash 1 'waiting pending)
    (relay--enqueue-callback conn (lambda () (setq ran t)))
    ;; Pump real timers: the queued callback must stay blocked behind the
    ;; still-`waiting' request rather than running.
    (let ((deadline (+ (float-time) 0.3)))
      (while (< (float-time) deadline) (sleep-for 0.02)))
    (should-not ran)
    ;; Resolving the blocked request must let the queued callback through.
    (remhash 1 pending)
    (let ((deadline (+ (float-time) 2.0)))
      (while (and (not ran) (< (float-time) deadline)) (sleep-for 0.02)))
    (should ran)))

(ert-deftest relay-slow-async-callback-does-not-block-ingestion-of-a-second-frame-in-the-same-chunk ()
  "Two replies arriving in one process-filter chunk must both be parsed and
routed before either callback runs -- a slow callback for the first must not
delay recognizing the second.

This is the specific, single-thread-compatible sense in which callbacks no
longer block frame ingestion: it does not mean two callbacks run
concurrently (Emacs Lisp has no concurrency), only that parsing/routing of
already-received bytes no longer waits on a callback's completion. Event
dispatch (`relay--handle-event') is unaffected by this change and remains
inline -- a slow event handler can still block ingestion; only reply/stream
callbacks were moved off the filter."
  (let* ((conn (relay-test--conn))
         (proc (make-pipe-process :name "relay-ingestion-test" :noquery t))
         (order nil)
         (id2-already-routed-when-id1-ran nil))
    (unwind-protect
        (progn
          (process-put proc 'relay-conn conn)
          (puthash 1 (lambda (_msg)
                       (push 'id1 order)
                       ;; If id2's frame had to wait for this callback, its
                       ;; entry would still be the pending function we
                       ;; installed below, not yet removed.
                       (setq id2-already-routed-when-id1-ran
                             (null (gethash 2 (relay-conn-pending conn)))))
                   (relay-conn-pending conn))
          (puthash 2 (lambda (_msg) (push 'id2 order)) (relay-conn-pending conn))
          (relay--filter proc (concat (relay-test--frame '(:id 1 :ok t))
                                      (relay-test--frame '(:id 2 :ok t))))
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (< (length order) 2) (< (float-time) deadline))
              (sleep-for 0.02)))
          (should id2-already-routed-when-id1-ran)
          ;; Order is still preserved (FIFO) even though both were deferred.
          (should (equal (reverse order) '(id1 id2))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest relay-cancel-request-makes-a-later-reply-a-no-op ()
  "After `relay--cancel-request', a reply for that id must not invoke the
callback that was registered for it -- the same silent-drop behavior as any
reply for an id relay never issued."
  (let* ((conn (relay-test--conn))
         (ran nil)
         (id (progn (puthash 1 (lambda (_msg) (setq ran t)) (relay-conn-pending conn))
                    1)))
    (relay--cancel-request conn id)
    (should-not (gethash id (relay-conn-pending conn)))
    ;; Cancelling twice, or an id nothing ever registered, must not error.
    (relay--cancel-request conn id)
    (relay--cancel-request conn 999)
    ;; A "late reply" for the cancelled id, routed exactly as relay--dispatch
    ;; would route it, finds nothing pending and is a no-op.
    (let ((entry (gethash id (relay-conn-pending conn))))
      (should-not (functionp entry)))
    (should-not ran)))

(ert-deftest relay-request-async-timeout-synthesizes-a-failure-and-cancels-the-id ()
  "TIMEOUT on `relay--request-async' fires a synthetic failure when no real
reply arrives in time, and the id is no longer pending afterward (so a real
reply that does eventually arrive is silently dropped, per
`relay--cancel-request')."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (proc (make-pipe-process :name "relay-timeout-test" :noquery t))
         (conn (relay--make-conn :process proc :authority "timeout-test"))
         (result nil)
         (id nil))
    (unwind-protect
        (progn
          (process-put proc 'relay-conn conn)
          ;; Never replied to: only the timeout can resolve this request.
          (setq id (relay--request-async conn "hello" nil
                                         (lambda (reply) (setq result reply))
                                         0.1))
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (not result) (< (float-time) deadline))
              (sleep-for 0.02)))
          (should result)
          (should-not (plist-get result :ok))
          (should (plist-get result :timeout))
          (should-not (gethash id (relay-conn-pending conn))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest relay-old-sentinel-cannot-remove-newer-reconnection ()
  "A late exit from an old SSH process must preserve its replacement."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (proc (make-pipe-process :name "relay-old-sentinel" :noquery t))
         (old (relay-test--conn "ssh+host"))
         (new (relay-test--conn "ssh+host")))
    (unwind-protect
        (progn
          (setf (relay-conn-process old) proc)
          (process-put proc 'relay-conn old)
          (puthash "ssh+host" new relay--connections)
          (delete-process proc)
          (relay--sentinel proc "deleted\n")
          (should (eq (gethash "ssh+host" relay--connections) new)))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest relay-minibuffer-completion-accepts-a-full-remote-file-argument ()
  "Interactive completion may put the remote prefix in FILE, not DIRECTORY."
  (let ((conn (relay-test--conn "ssh+devbox")))
    (cl-letf (((symbol-function 'relay--connection)
               (lambda (authority) (should (equal authority "ssh+devbox")) conn))
              ((symbol-function 'relay--listing)
               (lambda (_conn localdir)
                 (should (equal localdir "/work"))
                     '((:name "source" :kind "dir") (:name "README.md" :kind "file")))))
      (should (equal (relay--h-file-name-all-completions
                      "/relay:ssh+devbox:/work/so" default-directory)
                     '("source/"))))))

(ert-deftest relay-partial-completion-advertises-the-remote-transports ()
  "The first two completion steps expose relay and its transports."
  (should (equal (relay--partial-completion-candidates "/")
                 '("/relay:")))
  (should (equal (relay--partial-completion-candidates "/relay:")
                 '("/relay:local:/" "/relay:ssh+"))))

(ert-deftest relay-partial-completion-offers-ssh-host-aliases ()
  "SSH completion uses the cached host source without opening a connection."
  (let ((relay--ssh-host-cache '("devbox" "build-box")))
    (should (equal (relay--partial-completion-candidates "/relay:ssh+d")
                   '("/relay:ssh+devbox:/")))
    (should (equal (relay--partial-completion-candidates "/relay:ssh+")
                   '("/relay:ssh+build-box:/" "/relay:ssh+devbox:/")))))

(ert-deftest relay-register-invalidates-stale-empty-ssh-host-cache ()
  "Reloading the package must recover from an older cached no-match result."
  (let ((relay--ssh-host-cache nil))
    (relay-register)
    (should (eq relay--ssh-host-cache :uninitialized))))

(ert-deftest relay-ssh-host-discovery-recovers-from-legacy-nil-cache ()
  "A poisoned cache from an older live load must not mean no hosts forever."
  (let ((relay--ssh-host-cache nil))
    (cl-letf (((symbol-function 'relay--ssh-hosts-from-config)
               (lambda (_) '("devbox")))
              ((symbol-function 'relay--ssh-hosts-from-known-hosts)
               (lambda (_) nil)))
      (should (equal (relay--ssh-hosts) '("devbox")))
      (should (equal relay--ssh-host-cache '("devbox"))))))

(ert-deftest relay-ssh-source-paths-use-home-without-tilde-expansion ()
  "SSH discovery must survive a live session where `~' stays literal."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "HOME" "/mock-local-home")
    (should (equal (relay--ssh-user-file "config")
                   "/mock-local-home/.ssh/config"))
    (should (equal (relay--ssh-user-file "known_hosts")
                   "/mock-local-home/.ssh/known_hosts"))))

(ert-deftest relay-ssh-host-discovery-caches-a-real-empty-scan ()
  "A machine with no SSH sources should not reread them on every keystroke."
  (let ((relay--ssh-host-cache :uninitialized)
        (reads 0))
    (cl-letf (((symbol-function 'relay--ssh-hosts-from-config)
               (lambda (_) (cl-incf reads) nil))
              ((symbol-function 'relay--ssh-hosts-from-known-hosts)
               (lambda (_) (cl-incf reads) nil)))
      (should-not (relay--ssh-hosts))
      (should-not (relay--ssh-hosts))
      (should (eq relay--ssh-host-cache :empty))
      (should (= reads 2)))))

(ert-deftest relay-partial-completion-preserves-incomplete-directory-splits ()
  "Emacs may put an unfinished relay prefix in DIRECTORY, not FILE."
  (let ((minibuffer-completing-file-name t)
        (relay--ssh-host-cache '("devbox")))
    (should (equal (relay--completion-fullname "" "/relay:")
                   "/relay:"))
    (should (equal (relay--completion-fullname "ssh+" "/relay:")
                   "/relay:ssh+"))
    (should (equal (relay--completion-fullname "" "/relay:ssh+")
                   "/relay:ssh+"))
    (should (equal (relay--completion-fullname "m" "/relay:ssh+")
                   "/relay:ssh+m"))
    (should (equal (relay--minibuffer-completion-candidates
                    "" "/relay:ssh+")
                   '("devbox:/")))
    (should (equal (file-name-all-completions "" "/relay:ssh+")
                   '("devbox:/")))
    ;; This is the lower-level call made by `completion-file-name-table'.
    (should (equal (file-name-completion "" "/relay:ssh+" #'file-exists-p)
                   "devbox:/"))))

(ert-deftest relay-minibuffer-keeps-the-ssh-host-candidates ()
  "The real minibuffer table must not re-split ssh+ as a local path."
  (let ((minibuffer-completing-file-name t)
        (relay--ssh-host-cache '("devbox" "misc")))
    (let ((raw (completion-all-completions
                "/relay:ssh+" #'read-file-name-internal
                #'file-exists-p 1))
          candidates)
      ;; `completion-all-completions' returns a dotted list whose final cdr is
      ;; the completion boundary.  Keep only actual completion strings.
      (while (consp raw)
        (when (stringp (car raw)) (push (car raw) candidates))
        (setq raw (cdr raw)))
      (setq candidates (nreverse candidates))
      (setq candidates (mapcar #'substring-no-properties candidates))
      (should (equal candidates
                     '("devbox:/" "misc:/"))))))

(ert-deftest relay-minibuffer-completion-accepts-metadata-argument ()
  "Emacs 30 supplies a fifth METADATA argument on some minibuffer paths."
  (let ((minibuffer-completing-file-name t)
        (relay--ssh-host-cache '("devbox")))
    (let ((raw (completion-all-completions
                "/relay:ssh+" #'read-file-name-internal
                #'file-exists-p 1 '(metadata (category . file))))
          candidates)
      (while (consp raw)
        (when (stringp (car raw)) (push (car raw) candidates))
        (setq raw (cdr raw)))
      (should (equal (mapcar #'substring-no-properties (nreverse candidates))
                     '("devbox:/"))))))

(ert-deftest relay-ambiguous-prefix-is-not-an-exact-completion ()
  "The post-TAB exactness check must not turn host help into `No match'."
  (let ((minibuffer-completing-file-name t)
        (relay--ssh-host-cache '("devbox" "misc")))
    (should-not (test-completion "/relay:ssh+"
                                 #'read-file-name-internal #'file-exists-p))
    (should-not (test-completion "/relay:ssh+m"
                                 #'read-file-name-internal #'file-exists-p))))

(ert-deftest relay-tab-on-ambiguous-host-prefix-displays-help ()
  "Exercise the `minibuffer-complete' engine, not only its candidate table."
  (with-temp-buffer
    (insert "/relay:ssh+")
    (goto-char (point-max))
    (let ((minibuffer-completing-file-name t)
          (minibuffer-completion-table #'read-file-name-internal)
          (minibuffer-completion-predicate #'file-exists-p)
          (completion-auto-help t)
          (relay--ssh-host-cache '("devbox" "build-box"))
          helped)
      (cl-letf (((symbol-function 'minibuffer-completion-help)
                 (lambda (&rest _) (setq helped t)))
                ((symbol-function 'minibuffer-hide-completions) #'ignore))
        (should (= (completion--do-completion (point-min) (point-max)) 2))
        (should helped)
        (should (equal (buffer-string) "/relay:ssh+"))))))

(ert-deftest relay-real-minibuffer-table-keeps-root-candidate ()
  "`read-file-name-internal' must expose relay at `/ TAB' and `/r TAB'."
  (let ((minibuffer-completing-file-name t))
    (dolist (input '("/" "/r" "/re"))
      (let ((raw (completion-all-completions
                  input #'read-file-name-internal #'file-exists-p
                  (length input) '(metadata (category . file))))
            candidates)
        (while (consp raw)
          (when (stringp (car raw)) (push (car raw) candidates))
          (setq raw (cdr raw)))
        (should (member "relay:"
                        (mapcar #'substring-no-properties candidates)))))))

(ert-deftest relay-minibuffer-completion-is-registered-at-root ()
  "The actual file-name dispatch exposes relay beside local root entries."
  (let ((minibuffer-completing-file-name t)
        (relay--ssh-host-cache '("devbox")))
    (should (member "relay:" (file-name-all-completions "" "/")))
    (should (member "relay:" (file-name-all-completions "r" "/")))
    ;; This is the predicate `read-file-name' actually supplies.  At root the
    ;; common completion remains empty because relay is offered *alongside*
    ;; the ordinary root entries, rather than being inserted eagerly.
    (should (equal (file-name-completion "" "/" #'file-exists-p) ""))
    (should (equal (file-name-completion "relay:" "/" #'file-exists-p)
                   "relay:ssh+"))
    (should (equal (file-name-all-completions "relay:ssh+" "/")
                   '("relay:ssh+devbox:/")))))

(ert-deftest relay-remote-completion-adapts-file-name-predicates ()
  "Remote entry predicates receive expanded strings, not completion entries."
  (let ((conn (relay-test--conn "ssh+devbox")))
    (cl-letf (((symbol-function 'relay--connection) (lambda (_) conn))
              ((symbol-function 'relay--listing)
               (lambda (_ dir)
                 (should (equal dir "/tmp"))
                 '((:name "tmpfile" :kind "file")))))
      (should (equal (relay--h-file-name-completion
                      "tmp" "/relay:ssh+devbox:/tmp/"
                      (lambda (path)
                        (equal path "/relay:ssh+devbox:/tmp/tmpfile")))
                     "tmpfile")))))

(ert-deftest relay-incomplete-magic-name-gives-a-completion-error ()
  "Accepting the method candidate must never attempt a nil SSH authority."
  (with-temp-buffer
    (should-error (insert-file-contents "/relay:") :type 'user-error)))

(ert-deftest relay-parse-accepts-remote-home-shorthand ()
  "The server expands `~' relative to the remote account, not Emacs's home."
  (should (equal (relay--parse "/relay:ssh+devbox:~/")
                 '("ssh+devbox" . "~/")))
  (should (equal (relay--parse "/relay:ssh+devbox:~/project/file")
                 '("ssh+devbox" . "~/project/file"))))

(ert-deftest relay-expand-file-name-preserves-remote-home-shorthand ()
  "Local path normalization must not replace remote `~' with Emacs's home."
  (let ((default-directory "/"))
    (should (equal (expand-file-name "/relay:ssh+devbox:~/")
                   "/relay:ssh+devbox:~/"))
    (should (equal (expand-file-name "project/file"
                                    "/relay:ssh+devbox:~/")
                   "/relay:ssh+devbox:~/project/file"))))

(ert-deftest relay-make-auto-save-file-name-uses-the-local-transform ()
  "Opening a remote file must produce a valid, collision-safe auto-save name."
  (with-temp-buffer
    (let ((buffer-file-name "/relay:ssh+devbox:/project/src/example.el")
          (auto-save-file-name-transforms
           `((".*" ,temporary-file-directory t))))
      (let ((name (make-auto-save-file-name)))
        (should (string-prefix-p (file-name-as-directory temporary-file-directory)
                                 name))
        (should (auto-save-file-name-p (file-name-nondirectory name)))
        (should-not (file-remote-p name))
        ;; The uniquifying transform incorporates the complete remote name,
        ;; rather than colliding with example.el from another host/directory.
        (should (string-match-p (regexp-quote "relay:ssh+devbox") name))))))

(ert-deftest relay-find-file-enables-local-safety-features ()
  "A real visit enables local auto-save and permits push-based auto-revert."
  (require 'autorevert)
  (let* ((global-auto-revert-value
          (default-value 'auto-revert-remote-files))
         (relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (local (make-temp-file "relay-find-file-" nil ".el" "(message \"ok\")\n"))
         (remote (format "/relay:local:%s" local))
         (auto-save-file-name-transforms
          `((".*" ,temporary-file-directory t)))
         buffer auto-save-name)
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect remote))
          (with-current-buffer buffer
            ;; Batch-mode `after-find-file' intentionally skips this step;
            ;; interactive visits call it automatically.
            (auto-save-mode 1)
            (setq auto-save-name buffer-auto-save-file-name)
            (should (equal (buffer-string) "(message \"ok\")\n"))
            (should (stringp auto-save-name))
            (should-not (file-remote-p auto-save-name))
            (should (local-variable-p 'auto-revert-remote-files))
            (should auto-revert-remote-files)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (and auto-save-name (file-exists-p auto-save-name))
        (delete-file auto-save-name))
      (dolist (conn (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process conn))
          (delete-process (relay-conn-process conn))))
      (when (file-exists-p local)
        (delete-file local)))
    (should (eq (default-value 'auto-revert-remote-files)
                global-auto-revert-value))))

(ert-deftest relay-mustbenew-is-enforced-by-the-local-server ()
  "The server must atomically reject a second create-only write."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (local (make-temp-file "relay-mustbenew-"))
         (remote (format "/relay:local:%s" local)))
    (unwind-protect
        (progn
          (delete-file local)
          (relay--h-write-region "first" nil remote nil nil nil t)
          (should-error (relay--h-write-region "second" nil remote nil nil nil t)))
      (dolist (conn (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process conn))
          (delete-process (relay-conn-process conn))))
      (when (file-exists-p local) (delete-file local)))))

(ert-deftest relay-server-handles-a-bounded-request-burst ()
  "A burst larger than the worker queue must complete without lost replies.

This is deliberately local and metadata-only: it exercises framing, the
bounded work queue, and writer backpressure without creating remote load."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (conn (relay--connection "local"))
         (expected 100)
         (completed 0)
         (deadline (+ (float-time) 5.0)))
    (unwind-protect
        (progn
          (dotimes (_ expected)
            (relay--request-async
             conn "stat" (list :path temporary-file-directory)
             (lambda (reply)
               (when (plist-get reply :ok)
                 (cl-incf completed)))))
          (while (and (< completed expected) (< (float-time) deadline))
            (accept-process-output (relay-conn-process conn) 0.1))
          (should (= completed expected)))
      (when (process-live-p (relay-conn-process conn))
        (delete-process (relay-conn-process conn))))))

(ert-deftest relay-server-exits-when-its-input-reaches-eof ()
  "The long-lived server must not outlive the connection that launched it."
  (let* ((server (expand-file-name "server/target/debug/relay-server"
                                   relay-test--root))
         (stderr (generate-new-buffer " *relay-server-eof-stderr*"))
         (proc (make-process :name "relay-server-eof"
                             :command (list server)
                             :connection-type 'pipe
                             :coding 'binary
                             :noquery t
                             :stderr stderr))
         (deadline (+ (float-time) 2.0)))
    (unwind-protect
        (progn
          (should (process-live-p proc))
          (process-send-eof proc)
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (should-not (process-live-p proc))
          (should (= (process-exit-status proc) 0)))
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p stderr)
        (kill-buffer stderr)))))

(ert-deftest relay-server-disconnect-does-not-wait-for-a-blocked-request ()
  "EOF must stop the server even when a filesystem worker cannot finish."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (fifo (make-temp-name
                (expand-file-name "relay-blocked-read-" temporary-file-directory)))
         conn proc deadline)
    (unwind-protect
        (progn
          (should (= (call-process "mkfifo" nil nil nil fifo) 0))
          (setq conn (relay--connection "local")
                proc (relay-conn-process conn))
          ;; Opening a FIFO for reading blocks until a writer appears.  Once
          ;; the peer disconnects, no reply can be observed and the server
          ;; must not wait for this worker before terminating.
          (relay--request-async conn "read" (list :path fifo) #'ignore)
          (process-send-eof proc)
          (setq deadline (+ (float-time) 0.5))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (should-not (process-live-p proc)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (file-exists-p fifo)
        (delete-file fifo)))))

(ert-deftest relay-readdir-timeout-cleans-pending-stream ()
  "A timed-out stream must not retain callbacks for a late reply."
  (let* ((conn (relay-test--conn))
         (pending (relay-conn-pending conn))
         (ticks 0))
    (puthash 42 '(stream ignore . ignore) pending)
    (cl-letf (((symbol-function 'relay--readdir-all-async)
               (lambda (&rest _) 42))
              ((symbol-function 'accept-process-output) (lambda (&rest _) nil))
              ((symbol-function 'float-time) (lambda (&rest _) (cl-incf ticks))))
      (should-error (relay--readdir-all-sync conn "/root")))
    (should-not (gethash 42 pending))))

(ert-deftest relay-listing-installs-watch-asynchronously ()
  "A cold listing must not add a second blocking round trip for watch setup."
  (let ((conn (relay-test--conn)) async-ops)
    (cl-letf (((symbol-function 'relay--readdir-all-sync)
               (lambda (&rest _) '(:ok t :entries nil :self_attrs (:mtime 1 :mtime_nsec 0))))
              ((symbol-function 'relay--request)
               (lambda (&rest _) (error "synchronous watch")))
              ((symbol-function 'relay--request-async)
               (lambda (_conn op _args _callback) (push op async-ops))))
      (relay--listing conn "/root"))
    (should (member "watch" async-ops))))

(ert-deftest relay-reconnect-revalidation-is-asynchronous ()
  "Reconnecting with marks must not synchronously wait once per directory."
  (relay-test--with-clean-global-caches
   (let* ((conn (relay-test--conn))
          (key (cons "local" "/root")))
     (puthash key t relay--listing-prefetch-dirs)
     (puthash key '(:entries ((:name "a")) :mtime-key (1 . 0))
              relay--listing-prefetch-cache)
     (cl-letf (((symbol-function 'relay--request)
                (lambda (&rest _) (error "synchronous reconnect revalidation")))
               ((symbol-function 'relay--request-async)
                (lambda (_conn op _args callback)
                  (when (equal op "stat")
                    (funcall callback '(:ok t :attrs (:mtime 1 :mtime_nsec 0))))
                  1)))
       (relay--revalidate-marked-on-connect conn))
     (should (equal (gethash "/root" (relay-conn-dircache conn))
                    '((:name "a")))))))

(ert-deftest relay-remove-watch-is-asynchronous ()
  "Unwatch cleanup must not make buffer/watch teardown wait for the network."
  (let* ((relay--direct-watches (make-hash-table :test 'equal))
         (relay--connections (make-hash-table :test 'equal))
         (conn (relay-test--conn))
         (descriptor (relay--direct-watch-add "local" "/root" #'ignore))
         async-ops)
    (puthash "local" conn relay--connections)
    (cl-letf (((symbol-function 'relay--request)
               (lambda (&rest _) (error "synchronous unwatch")))
              ((symbol-function 'relay--request-async)
               (lambda (_conn op _args _callback) (push op async-ops)))
              ((symbol-function 'process-live-p) (lambda (&rest _) t)))
      (relay--h-file-notify-rm-watch descriptor))
    (should (member "unwatch" async-ops))))

(ert-deftest relay-rewatch-direct-on-connect-resends-watch-and-emits-resync ()
  "Reconnecting must re-register every direct watch for that authority with
the new connection and deliver a synthetic `changed' event to each -- the
resync signal a caller needs after potentially missing real changes while
disconnected. This is the core of the reconnect-survival fix: the old
`relay-conn-watches' table lived on the connection object itself, so a
reconnect (a brand new `relay-conn') silently lost every registration with
no error and no notification -- see `relay--direct-watches's header
comment in relay-core.el."
  (let* ((relay--direct-watches (make-hash-table :test 'equal))
         (new-conn (relay-test--conn "local"))
         received
         watch-ops
         (descriptor (relay--direct-watch-add
                      "local" "/root" (lambda (event) (push event received)))))
    (cl-letf (((symbol-function 'relay--request-async)
               (lambda (_conn op args _callback) (push (cons op args) watch-ops) 1))
              ((symbol-function 'run-at-time)
               (lambda (_delay _repeat function &rest args) (apply function args))))
      (relay--rewatch-direct-on-connect new-conn))
    (should (equal (caar watch-ops) "watch"))
    (should (equal (plist-get (cdar watch-ops) :path) "/root"))
    (should (= (length received) 1))
    (should (equal (nth 0 (car received)) descriptor))
    (should (eq (nth 1 (car received)) 'changed))
    (should (equal (nth 2 (car received)) "/relay:local:/root"))))

(ert-deftest relay-connect-reconnect-rewatches-and-resyncs-direct-watch ()
  "End-to-end against a real local server: after the underlying transport
dies and `relay--connection' establishes a genuinely new connection for the
same authority, a direct watch registered before the death is still live --
re-sent to the server and its callback resynced -- without the caller
having done anything itself to recover it."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay--direct-watches (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (dir (make-temp-file "relay-rewatch-test-" t))
         received
         (conn1 (relay--connection "local")))
    (unwind-protect
        (progn
          (relay--h-file-notify-add-watch
           (format "/relay:local:%s" dir) '(change)
           (lambda (event) (push event received)))
          (should (relay--direct-watches-for "local" (directory-file-name dir)))
          ;; Kill the underlying transport to force a reconnect on next use.
          (delete-process (relay-conn-process conn1))
          (let ((conn2 (relay--connection "local")))
            (should-not (eq conn1 conn2))
            (let ((deadline (+ (float-time) 3.0)))
              (while (and (not received) (< (float-time) deadline))
                (sleep-for 0.02)))
            (should received)
            (should (eq (nth 1 (car received)) 'changed))))
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-directory-p dir) (delete-directory dir t)))))

;;;; ---------------------------------------------------------------------------
;;;; Async connection establishment

(ert-deftest relay-connect-async-succeeds-against-a-real-local-server ()
  "A successful async connection fires on-ready with a ready relay-conn."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (done nil)
         (conn-result nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (relay-connect-async "local"
                               (lambda (conn)
                                 (setq conn-result conn done t))
                               (lambda (_err) (setq done t)))
          ;; Wait for the callback to fire.
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should conn-result)
          (should (relay-conn-ready conn-result))
          (should (relay-conn-hello conn-result))
          (should (process-live-p (relay-conn-process conn-result))))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

(ert-deftest relay-connect-async-succeeds-for-an-authority-already-connected-synchronously ()
  "`relay-connect-async' must recognize a connection `relay--connection'
already established synchronously as ready, and call on-ready promptly --
not silently hang forever.

This is the exact sequence a real caller produces: something on a
synchronous path (e.g. `relay-exec-raw' via `muster-chat-tmux--send-keys')
connects an authority first, then something else calls
`relay-connect-async' for that same authority. If the synchronous path ever
stopped setting `relay-conn-ready', this would regress silently: every other
async test in this file starts from a fresh `relay--connections' table, so
none of them exercise a pre-existing synchronously-established connection."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (sync-conn (relay--connection "local"))
         (done nil)
         (conn-result nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (should (relay-conn-ready sync-conn))
          (relay-connect-async "local"
                               (lambda (conn) (setq conn-result conn done t))
                               (lambda (_err) (setq done t)))
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should (eq conn-result sync-conn)))
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

(ert-deftest relay-connect-async-fans-concurrent-callers-to-one-connect ()
  "Two concurrent relay-connect-async calls for the same authority spawn exactly
one process and both callbacks receive the same relay-conn object."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (orig (symbol-function 'make-process))
         (spawns 0)
         (ready-count 0)
         (conns '())
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          ;; Count process spawns via a wrapper.
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args) (cl-incf spawns) (apply orig args))))
            ;; Issue two relay-connect-async calls back-to-back (no event loop
            ;; between them) for the same authority.
            (relay-connect-async "local"
                                 (lambda (conn) (push conn conns) (cl-incf ready-count))
                                 #'ignore)
            (relay-connect-async "local"
                                 (lambda (conn) (push conn conns) (cl-incf ready-count))
                                 #'ignore)
            ;; Wait for both callbacks to fire.
            (while (and (< ready-count 2) (< (float-time) deadline))
              (sleep-for 0.02)))
          ;; Assertions: exactly one spawn, both conns are eq and ready.
          (should (= spawns 1))
          (should (= ready-count 2))
          (should (= (length conns) 2))
          (should (eq (car conns) (cadr conns)))
          (should (relay-conn-ready (car conns))))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

(ert-deftest relay-connect-async-calls-on-error-for-a-bad-authority ()
  "An unknown transport (bad authority) fires on-error asynchronously."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (done nil)
         (error-result nil)
         (deadline (+ (float-time) 1.0)))
    (relay-connect-async "no-such-authority"
                         (lambda (_conn) (setq done t))
                         (lambda (err) (setq error-result err done t)))
    ;; Wait for the callback to fire.
    (while (and (not done) (< (float-time) deadline))
      (sleep-for 0.02))
    (should done)
    (should-not (gethash "no-such-authority" relay--connections))
    (should error-result)
    (should (plist-get error-result :error))))

(ert-deftest relay-connect-async-calls-on-error-when-transport-dies ()
  "If the server process exits immediately (e.g., binary not found or 'false'),
on-error is called asynchronously with a transport error."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path (executable-find "false"))
         (done nil)
         (error-result nil)
         (deadline (+ (float-time) 2.0)))
    (unwind-protect
        (progn
          (relay-connect-async "local"
                               (lambda (_conn) (setq done t))
                               (lambda (err) (setq error-result err done t)))
          ;; Wait for the callback to fire (the false process dies instantly).
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should error-result)
          (should (plist-get error-result :error)))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c)))))))

;;;; ---------------------------------------------------------------------------
;;;; Async tail-read primitives

(ert-deftest relay-tail-read-async-basic-read ()
  "A basic tail-read must return bytes, offsets, file size, dev/ino, and truncation status."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-basic-"))
         (content "Hello, World!")
         (result nil)
         (error-result nil)
         (done nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (write-region content nil tmpfile)
          (relay-tail-read-async "local" tmpfile 0 nil nil 1024
                                 (lambda (r) (setq result r done t))
                                 (lambda (e) (setq error-result e done t)))
          ;; Wait for the callback to fire.
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should-not error-result)
          (should result)
          ;; Check the returned bytes
          (should (equal (plist-get result :bytes) content))
          ;; Check offsets
          (should (= (plist-get result :start) 0))
          (should (= (plist-get result :actual-end) (length content)))
          ;; Check file size
          (should (= (plist-get result :file-size) (length content)))
          ;; Check truncation status (should not be truncated on fresh read)
          (should-not (plist-get result :truncated-or-rotated))
          ;; Check more-available (shouldn't have more since we read everything)
          (should-not (plist-get result :more-available))
          ;; Check dev/ino are present (actual values don't matter)
          (should (integerp (plist-get result :dev)))
          (should (integerp (plist-get result :ino))))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-async-append-tolerance ()
  "A tail-read with known-dev/known-ino must tolerate appends and continue from known-offset."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-append-"))
         (content1 "First ")
         (content2 "Second ")
         (first-result nil)
         (second-result nil)
         (error-result nil)
         (done-count 0)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          ;; First read: get initial content
          (write-region content1 nil tmpfile)
          (relay-tail-read-async "local" tmpfile 0 nil nil 1024
                                 (lambda (r)
                                   (setq first-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for first callback
          (while (and (= done-count 0) (< (float-time) deadline))
            (sleep-for 0.02))
          (should first-result)
          (should-not error-result)
          (should (equal (plist-get first-result :bytes) content1))

          ;; Append more content to the file (write directly, not through relay)
          (write-region content2 nil tmpfile t)

          ;; Second read: use known-offset/dev/ino from first read
          (relay-tail-read-async "local" tmpfile
                                 (plist-get first-result :actual-end)
                                 (plist-get first-result :dev)
                                 (plist-get first-result :ino)
                                 1024
                                 (lambda (r)
                                   (setq second-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for second callback
          (while (and (< done-count 2) (< (float-time) deadline))
            (sleep-for 0.02))
          (should second-result)
          (should-not error-result)
          ;; Should get the appended content, not truncated
          (should (equal (plist-get second-result :bytes) content2))
          (should-not (plist-get second-result :truncated-or-rotated)))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-async-truncation-detection ()
  "A file rotation/truncation must set truncated-or-rotated and re-anchor at 0."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-truncate-"))
         (content1 "Long original content ")
         (content2 "Short")
         (first-result nil)
         (second-result nil)
         (error-result nil)
         (done-count 0)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          ;; First read: get initial content
          (write-region content1 nil tmpfile)
          (relay-tail-read-async "local" tmpfile 0 nil nil 1024
                                 (lambda (r)
                                   (setq first-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for first callback
          (while (and (= done-count 0) (< (float-time) deadline))
            (sleep-for 0.02))
          (should first-result)
          (should-not error-result)

          ;; Delete and recreate the file with different content
          (delete-file tmpfile)
          (write-region content2 nil tmpfile)

          ;; Second read: use known-offset/dev/ino from first read
          ;; Since the file was deleted/recreated, dev/ino will change
          (relay-tail-read-async "local" tmpfile
                                 (plist-get first-result :actual-end)
                                 (plist-get first-result :dev)
                                 (plist-get first-result :ino)
                                 1024
                                 (lambda (r)
                                   (setq second-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for second callback
          (while (and (< done-count 2) (< (float-time) deadline))
            (sleep-for 0.02))
          (should second-result)
          (should-not error-result)
          ;; Should report truncated-or-rotated and start from 0
          (should (plist-get second-result :truncated-or-rotated))
          (should (= (plist-get second-result :start) 0))
          ;; Should return the new file's content
          (should (equal (plist-get second-result :bytes) content2)))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-async-max-bytes-capping ()
  "A read with small max-bytes must cap the result and set more-available."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-maxbytes-"))
         (content "0123456789abcdefghijklmnopqrstuvwxyz")
         (first-result nil)
         (second-result nil)
         (error-result nil)
         (done-count 0)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          ;; Write a file larger than our max-bytes
          (write-region content nil tmpfile)

          ;; First read: request only 10 bytes
          (relay-tail-read-async "local" tmpfile 0 nil nil 10
                                 (lambda (r)
                                   (setq first-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for first callback
          (while (and (= done-count 0) (< (float-time) deadline))
            (sleep-for 0.02))
          (should first-result)
          (should-not error-result)
          ;; Should have exactly 10 bytes
          (should (= (length (plist-get first-result :bytes)) 10))
          (should (equal (plist-get first-result :bytes) "0123456789"))
          (should (= (plist-get first-result :actual-end) 10))
          ;; More should be available since file is 37 bytes
          (should (plist-get first-result :more-available))

          ;; Second read: continue from first actual-end
          (relay-tail-read-async "local" tmpfile
                                 (plist-get first-result :actual-end)
                                 (plist-get first-result :dev)
                                 (plist-get first-result :ino)
                                 10
                                 (lambda (r)
                                   (setq second-result r)
                                   (cl-incf done-count))
                                 (lambda (e) (setq error-result e)))
          ;; Wait for second callback
          (while (and (< done-count 2) (< (float-time) deadline))
            (sleep-for 0.02))
          (should second-result)
          (should-not error-result)
          ;; Should have next 10 bytes
          (should (= (length (plist-get second-result :bytes)) 10))
          (should (equal (plist-get second-result :bytes) "abcdefghij"))
          ;; Still more available
          (should (plist-get second-result :more-available)))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-async-missing-capability ()
  "A missing tail-read-v1 capability must call on-error with a clear message."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-nocap-"))
         (result nil)
         (error-result nil)
         (done nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (write-region "test content" nil tmpfile)
          ;; Get a real connection first to verify it supports tail-read-v1
          (let ((conn (relay--connection "local")))
            ;; Stub relay-connect-async to provide a connection without tail-read-v1
            (cl-letf (((symbol-function 'relay-connect-async)
                       (lambda (_authority on-ready _on-error)
                         ;; Create a fake connection with no tail-read capability
                         (let* ((capabilities (plist-get (relay-conn-hello conn) :capabilities))
                                ;; Remove tail-read-v1 from the capability list
                                (modified-hello (list :protocol_version 1
                                                      :capabilities (remove "tail-read-v1" capabilities))))
                           ;; Call on-ready with a test connection that has the modified hello
                           (let ((fake-conn (relay-test--conn "local")))
                             (setf (relay-conn-hello fake-conn) modified-hello)
                             (funcall on-ready fake-conn))))))
              (relay-tail-read-async "local" tmpfile 0 nil nil 1024
                                     (lambda (r) (setq result r done t))
                                     (lambda (e) (setq error-result e done t))))
            ;; Wait for the callback to fire
            (while (and (not done) (< (float-time) deadline))
              (sleep-for 0.02))
            ;; Clean up the real connection
            (when (process-live-p (relay-conn-process conn))
              (delete-process (relay-conn-process conn))))

          ;; Should not have called on-success
          (should-not result)
          ;; Should have called on-error
          (should error-result)
          ;; Error should mention the missing capability
          (should (plist-get error-result :error))
          (should (string-match-p "tail-read" (plist-get error-result :error))))
      ;; Cleanup
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

;;;; ---------------------------------------------------------------------------
;;;; relay-tail-read-chunked-async

(ert-deftest relay-tail-read-chunked-async-multi-chunk-real-file ()
  "A file larger than the server's per-request cap (1 MiB) must be assembled
across more than one real chunk request, matching a full direct read."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-chunked-multi-"))
         ;; Larger than the server's 1 MiB per-request cap so the client must
         ;; issue at least two real chunk requests to reach EOF.
         (content (make-string (+ (* 1024 1024) 500) ?x))
         (result nil)
         (error-result nil)
         (done nil)
         (deadline (+ (float-time) 8.0)))
    (unwind-protect
        (progn
          (write-region content nil tmpfile)
          (relay-tail-read-chunked-async
           "local" tmpfile 0 nil nil
           (lambda (r) (setq result r done t))
           (lambda (e) (setq error-result e done t)))
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should-not error-result)
          (should result)
          (should (= (length (plist-get result :bytes)) (length content)))
          (should (equal (plist-get result :bytes) content))
          (should (= (plist-get result :start) 0))
          (should (= (plist-get result :actual-end) (length content)))
          (should (= (plist-get result :file-size) (length content)))
          (should-not (plist-get result :truncated-or-rotated))
          (should-not (plist-get result :more-available))
          (should (eq (plist-get result :outcome) 'complete))
          (should (integerp (plist-get result :dev)))
          (should (integerp (plist-get result :ino))))
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-chunked-async-total-bytes-cap ()
  "relay-tail-read-max-total-bytes must stop the sequence before EOF and
report more-available, without a second chunk request's bytes ever being
appended -- proven by asserting the exact capped prefix, not just a count."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (relay-tail-read-max-total-bytes 10)
         (tmpfile (make-temp-file "relay-tail-read-chunked-cap-"))
         (content "0123456789abcdefghij")
         (result nil)
         (error-result nil)
         (done nil)
         (deadline (+ (float-time) 3.0)))
    (unwind-protect
        (progn
          (write-region content nil tmpfile)
          (relay-tail-read-chunked-async
           "local" tmpfile 0 nil nil
           (lambda (r) (setq result r done t))
           (lambda (e) (setq error-result e done t)))
          (while (and (not done) (< (float-time) deadline))
            (sleep-for 0.02))
          (should done)
          (should-not error-result)
          (should result)
          (should (equal (plist-get result :bytes) "0123456789"))
          (should (= (plist-get result :actual-end) 10))
          (should (eq (plist-get result :outcome) 'capped))
          (should (plist-get result :more-available)))
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-chunked-async-cancel-suppresses-delivery ()
  "Cancelling the returned token must suppress both on-success and on-error,
even for a reply already in flight when cancellation happens."
  (let* ((relay--connections (make-hash-table :test 'equal))
         (relay-server-local-path
          (expand-file-name "server/target/debug/relay-server" relay-test--root))
         (tmpfile (make-temp-file "relay-tail-read-chunked-cancel-"))
         (result nil)
         (error-result nil)
         (token nil))
    (unwind-protect
        (progn
          (write-region "content" nil tmpfile)
          (setq token
                (relay-tail-read-chunked-async
                 "local" tmpfile 0 nil nil
                 (lambda (r) (setq result r))
                 (lambda (e) (setq error-result e))))
          (relay-tail-read-cancel token)
          ;; Give any in-flight reply time to arrive and be discarded.
          (let ((deadline (+ (float-time) 1.0)))
            (while (< (float-time) deadline)
              (sleep-for 0.02)))
          (should-not result)
          (should-not error-result)
          ;; Cancelling twice must remain harmless.
          (relay-tail-read-cancel token))
      (dolist (c (relay-test--hash-values relay--connections))
        (when (process-live-p (relay-conn-process c))
          (delete-process (relay-conn-process c))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

(ert-deftest relay-tail-read-chunked-async-stops-on-mid-sequence-rotation ()
  "A rotation/truncation surfaced on a later chunk (not the first) must stop
the sequence immediately, discard every earlier chunk's bytes (they came
from a now-rotated-away file), and deliver exactly the rotated reply's own
bytes -- never a concatenation spanning both files. Uses a stubbed
relay-tail-read-async so the rotation is deterministic instead of racing a
real file swap against real network chunk timing."
  (let* ((calls 0)
         (result nil)
         (error-result nil)
         (done nil))
    (cl-letf (((symbol-function 'relay-tail-read-async)
               (lambda (_authority _path _offset _dev _ino _max-bytes on-success _on-error)
                 (cl-incf calls)
                 (run-at-time
                  0 nil
                  (lambda ()
                    (if (= calls 1)
                        ;; First chunk: normal read, more available, identity 100/200.
                        (funcall on-success
                                 (list :bytes "first-chunk-" :start 0 :actual-end 12
                                       :file-size 999 :dev 100 :ino 200
                                       :truncated-or-rotated nil :more-available t))
                      ;; Second chunk: the identity forwarded from chunk 1
                      ;; (100/200) no longer matches on the server -- a
                      ;; rotation between chunk 1 and chunk 2, not before
                      ;; chunk 1. The server re-anchors at byte 0 of the new
                      ;; file and returns that new file's own bytes.
                      (funcall on-success
                               (list :bytes "rotated-content" :start 0 :actual-end 15
                                     :file-size 15 :dev 999 :ino 888
                                     :truncated-or-rotated t :more-available nil))))))))
      (relay-tail-read-chunked-async
       "local" "/fake/path" 0 nil nil
       (lambda (r) (setq result r done t))
       (lambda (e) (setq error-result e done t)))
      (let ((deadline (+ (float-time) 2.0)))
        (while (and (not done) (< (float-time) deadline))
          (sleep-for 0.02)))
      (should done)
      (should-not error-result)
      (should result)
      (should (= calls 2))
      ;; Must reflect only the rotated chunk's own bytes -- not
      ;; "first-chunk-rotated-content", which would silently splice the old
      ;; and new files together.
      (should (equal (plist-get result :bytes) "rotated-content"))
      (should (plist-get result :truncated-or-rotated))
      (should (eq (plist-get result :outcome) 'rotated))
      (should (= (plist-get result :dev) 999))
      (should (= (plist-get result :ino) 888)))))

;;; relay-tests.el ends here

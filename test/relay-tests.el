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
   :dircache-mtime (make-hash-table :test 'equal)
   :watches (make-hash-table :test 'equal)))

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
  (let* ((conn (relay-test--conn))
         (path "/root/file.txt")
         (descriptor (cons conn 17))
         received)
    (puthash path
             (list (cons descriptor (lambda (event) (setq received event))))
             (relay-conn-watches conn))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_delay _repeat function &rest args) (apply function args))))
      (relay--handle-event conn (list :event "self_changed" :dir path)))
    (should received)
    (should (equal (nth 0 received) descriptor))
    (should (eq (nth 1 received) 'changed))
    (should (equal (nth 2 received) "/relay:local:/root/file.txt"))))

(ert-deftest relay-file-notify-rejects-a-failed-server-watch ()
  "Never return a valid-looking descriptor when the OS watch was rejected."
  (let ((conn (relay-test--conn)))
    (cl-letf (((symbol-function 'relay--connection) (lambda (_) conn))
              ((symbol-function 'relay--request)
               (lambda (&rest _) (error "watch resources exhausted"))))
      (should-error
       (relay--h-file-notify-add-watch
        "/relay:local:/root/file.txt" '(change) #'ignore))
      (should (= (hash-table-count (relay-conn-watches conn)) 0)))))

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
  (let* ((conn (relay-test--conn))
         (descriptor (cons conn 9))
         async-ops)
    (puthash "/root" (list (cons descriptor #'ignore)) (relay-conn-watches conn))
    (cl-letf (((symbol-function 'relay--request)
               (lambda (&rest _) (error "synchronous unwatch")))
              ((symbol-function 'relay--request-async)
               (lambda (_conn op _args _callback) (push op async-ops))))
      (relay--h-file-notify-rm-watch descriptor))
    (should (member "unwatch" async-ops))))

;;; relay-tests.el ends here

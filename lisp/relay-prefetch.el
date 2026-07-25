;;; relay-prefetch.el --- Remote directory and content prefetch -*- lexical-binding: t; -*-

;;; Code:

(require 'relay-core)

;; Implemented by relay-content-prefetch.  Keep this dependency dynamic:
;; listing/cache invalidation also works when byte-prefetch support is not
;; loaded, and requiring it here would create a cycle.
(declare-function relay--content-cache-evict-prefix
                  "relay-content-prefetch" (authority localdir))
(declare-function relay--content-cache-evict-authority
                  "relay-content-prefetch" (authority))
(declare-function relay--content-prefetch-warm
                  "relay-content-prefetch" (conn localdir))

;;;; Directory cache + freshness

;;;; Prefetch: two independent mechanisms, "listing" (metadata: names/stat,
;;;; never file bytes) and "content" (actual file bytes, LRU-bounded — more
;;;; dangerous, off by default, deliberately not implied by listing-prefetch).
;;;; Model, settled after several false starts this session (see
;;;; JOURNAL.md): marking a directory only ever affects that EXACT directory
;;;; — never its children, not even one level down. To warm a subdirectory
;;;; too, mark it separately. This is deliberately simpler than earlier
;;;; drafts that tried to bound an eager-fan-out-into-children mechanic with
;;;; size/count caps — the call was that any automatic cascade into children
;;;; is the wrong shape, not something to merely bound.

(defcustom relay-prefetch-config-file
  (locate-user-emacs-file "relay-prefetch.el")
  "File where listing/content prefetch marks are persisted as plain Lisp
data, so they survive across Emacs sessions — not just reconnects within one
(that's `relay--listing-prefetch-cache', a separate, unrelated mechanism).

Deliberately a dedicated file, not folded into `custom-file': keeping the
mark data in one small, simply-structured, plain-data file makes it
straightforward for a future interactive tree-browser (see JOURNAL.md — not
built yet) to read and rewrite it directly, without needing to parse or
preserve whatever else happens to be in the user's general customizations."
  :type 'file :group 'relay)

(defconst relay--prefetch-config-version 2)

(defvar relay--prefetch-profiles (make-hash-table :test 'equal)
  "Profile name -> plist with `:name', `:root', `:listing', and `:content'.")

(defvar relay--prefetch-active-profiles '("default")
  "Names of profiles whose marks are currently active.")

(defvar relay--prefetch-selected-profile "default"
  "Profile edited by the ordinary mark/unmark commands and the Dired UI.")

(defvar relay--prefetch-problems (make-hash-table :test 'equal)
  "Active profile key -> latest asynchronous rewarm error string.

This is deliberately session-only: the profile remains durable intent, while
availability is retried when the profile is next activated or Emacs restarts.")

(defvar relay--listing-prefetch-dirs (make-hash-table :test 'equal)
  "Set of (AUTHORITY . LOCALDIR) pairs marked for listing prefetch via
`relay-mark-listing-prefetch'. Keyed independently of any particular
`relay-conn' instance so marks survive a server reconnect within the same
Emacs session (and, via `relay-prefetch-config-file', across sessions too).
Marking affects only the exact directory named — never its children, not
even immediate ones; each directory worth warming needs its own separate
mark.")

(defvar relay--content-prefetch-dirs (make-hash-table :test 'equal)
  "Set of (AUTHORITY . LOCALDIR) pairs marked for content prefetch via
`relay-mark-content-prefetch'. Same shape and persistence story as
`relay--listing-prefetch-dirs', but a wholly separate, independently
controlled mechanism — see the content-prefetch section below.")

(defvar relay--listing-prefetch-cache (make-hash-table :test 'equal)
  "Session cache of listings and mtimes for marked remote directories.

Keys are (AUTHORITY . LOCALDIR). Values are
`(:entries LIST :mtime-key (SECONDS . NSEC))'. The cache survives connection
replacement, allowing `relay--revalidate-marked-on-connect' to use a cheap
stat before deciding whether to re-read a directory. It is never persisted
across Emacs sessions.")

(defun relay--hash-keys (table)
  (let (out) (maphash (lambda (k _v) (push k out)) table) out))

(defun relay--prefetch-profile-names ()
  "Return configured profile names in stable display order."
  (sort (relay--hash-keys relay--prefetch-profiles) #'string<))

(defun relay--prefetch-profile (name)
  "Return the profile named NAME, or nil."
  (gethash name relay--prefetch-profiles))

(defun relay--prefetch-ensure-profile (name &optional root)
  "Create NAME if necessary and return its profile plist."
  (or (relay--prefetch-profile name)
      (let ((profile (list :name name :root root :listing nil :content nil)))
        (puthash name profile relay--prefetch-profiles)
        profile)))

(defun relay--prefetch-profile-put (name profile)
  "Store PROFILE under NAME, preserving its canonical name field."
  (puthash name (plist-put (copy-sequence profile) :name name)
           relay--prefetch-profiles))

(defun relay--prefetch-profile-add-key (name kind key)
  "Add KEY to KIND (`:listing' or `:content') in profile NAME."
  (let* ((profile (relay--prefetch-ensure-profile name))
         (keys (plist-get profile kind)))
    (unless (member key keys)
      (setq profile (plist-put (copy-sequence profile) kind (cons key keys)))
      (relay--prefetch-profile-put name profile))))

(defun relay--prefetch-profile-remove-key (name kind key)
  "Remove KEY from KIND (`:listing' or `:content') in profile NAME."
  (let ((profile (relay--prefetch-profile name)))
    (when profile
      (setq profile
            (plist-put (copy-sequence profile) kind
                       (delete key (copy-sequence (plist-get profile kind)))))
      (relay--prefetch-profile-put name profile))))

(defun relay--prefetch-rebuild-live-marks ()
  "Recompute the live mark sets from `relay--prefetch-active-profiles'."
  (clrhash relay--listing-prefetch-dirs)
  (clrhash relay--content-prefetch-dirs)
  (dolist (name relay--prefetch-active-profiles)
    (let ((profile (relay--prefetch-profile name)))
      (when profile
        (dolist (key (plist-get profile :listing))
          (puthash key t relay--listing-prefetch-dirs))
        (dolist (key (plist-get profile :content))
          (puthash key t relay--content-prefetch-dirs)))))
  ;; Drop names that were deleted or malformed on disk.
  (setq relay--prefetch-active-profiles
        (seq-filter #'relay--prefetch-profile relay--prefetch-active-profiles))
  (unless (relay--prefetch-profile relay--prefetch-selected-profile)
    (setq relay--prefetch-selected-profile
          (or (car relay--prefetch-active-profiles) "default"))))

(defun relay--prefetch-key-active-p (key)
  "Non-nil if KEY is still owned by any active prefetch profile."
  (or (gethash key relay--listing-prefetch-dirs)
      (gethash key relay--content-prefetch-dirs)))

(defun relay--prefetch-evict-deactivated (old-listing old-content)
  "Release caches for marks removed while switching active profiles."
  (dolist (key old-listing)
    (unless (gethash key relay--listing-prefetch-dirs)
      (remhash key relay--listing-prefetch-cache)
      (unless (gethash key relay--content-prefetch-dirs)
        (remhash key relay--prefetch-problems))
      (let ((conn (gethash (car key) relay--connections)))
        (when conn (relay--dircache-evict-prefix conn (cdr key))))))
  (dolist (key old-content)
    (unless (gethash key relay--content-prefetch-dirs)
      (relay--content-cache-evict-prefix (car key) (cdr key)))
    (unless (relay--prefetch-key-active-p key)
      (remhash key relay--prefetch-problems))))

(defun relay--prefetch-apply-active-profiles ()
  "Apply active profiles and rewarm current connections without blocking."
  (let ((old-listing (relay--hash-keys relay--listing-prefetch-dirs))
        (old-content (relay--hash-keys relay--content-prefetch-dirs)))
    (relay--prefetch-rebuild-live-marks)
    (relay--prefetch-evict-deactivated old-listing old-content)
    (maphash (lambda (_ conn)
               (when (process-live-p (relay-conn-process conn))
                 (relay--rewarm-marked conn)))
             relay--connections)))

(defun relay-prefetch-profile-problems (&optional profile)
  "Return `(KEY . ERROR)' entries for active PROFILE's unavailable folders.

When PROFILE is nil, inspect `relay--prefetch-selected-profile'."
  (let* ((profile (relay--prefetch-profile
                   (or profile relay--prefetch-selected-profile)))
         (keys (delete-dups (append (copy-sequence (plist-get profile :listing))
                                    (copy-sequence (plist-get profile :content)))))
         problems)
    (dolist (key keys)
      (when-let ((error (gethash key relay--prefetch-problems)))
        (push (cons key error) problems)))
    (nreverse problems)))

;;;###autoload
(defun relay-prefetch-retry-profile-problems (&optional profile)
  "Asynchronously retry unavailable folders in PROFILE.

The command is safe while disconnected: folders whose authority has no live
connection remain reported as unavailable until that profile/host is used."
  (interactive)
  (let ((problems (relay-prefetch-profile-problems profile)))
    (dolist (problem problems)
      (let* ((key (car problem))
             (conn (gethash (car key) relay--connections)))
        (when (and conn (process-live-p (relay-conn-process conn)))
          (relay--listing-rewarm-async conn (cdr key)))))
    (message "relay: retrying %d unavailable prefetch folder%s"
             (length problems) (if (= (length problems) 1) "" "s"))))

(defun relay--prefetch-config-load ()
  "Load profiles from `relay-prefetch-config-file' into the live mark sets.

Version-1 files containing top-level `:listing' and `:content' are migrated in
memory into the `default' profile.  The cache data itself remains session-only."
  (clrhash relay--prefetch-profiles)
  (let ((data (when (file-exists-p relay-prefetch-config-file)
                (with-temp-buffer
                  (insert-file-contents relay-prefetch-config-file)
                  (unless (eobp) (read (current-buffer)))))))
    (if (plist-member data :profiles)
        (progn
          (dolist (profile (plist-get data :profiles))
            (let ((name (plist-get profile :name)))
              (when (and (stringp name) (not (string-empty-p name)))
                (relay--prefetch-profile-put
                 name (list :name name :root (plist-get profile :root)
                            :listing (copy-sequence (plist-get profile :listing))
                            :content (copy-sequence (plist-get profile :content)))))))
          (setq relay--prefetch-active-profiles
                (copy-sequence (or (plist-get data :active) '("default"))))
          (setq relay--prefetch-selected-profile
                (or (plist-get data :selected) (car relay--prefetch-active-profiles)
                    "default")))
      (let ((legacy (list :name "default"
                          :listing (copy-sequence (plist-get data :listing))
                          :content (copy-sequence (plist-get data :content)))))
        (relay--prefetch-profile-put "default" legacy)
        (setq relay--prefetch-active-profiles '("default")
              relay--prefetch-selected-profile "default")))
    (unless (relay--prefetch-profile "default")
      (relay--prefetch-ensure-profile "default"))
    (relay--prefetch-rebuild-live-marks)))

(defun relay--prefetch-config-save ()
  "Persist named profiles and their active state as plain readable data."
  (let ((dir (file-name-directory relay-prefetch-config-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (with-temp-file relay-prefetch-config-file
    (let ((print-length nil) (print-level nil))
      (insert ";; relay listing/content prefetch marks.\n"
              ";; Auto-generated, but plain data -- safe to hand-edit.\n")
      (prin1 (list :version relay--prefetch-config-version
                   :profiles (mapcar #'relay--prefetch-profile
                                     (relay--prefetch-profile-names))
                   :active relay--prefetch-active-profiles
                   :selected relay--prefetch-selected-profile)
             (current-buffer))
      (insert "\n"))))

;;;###autoload
(defun relay-prefetch-create-profile (name &optional root)
  "Create profile NAME, optionally associated with remote directory ROOT."
  (interactive (list (read-string "New relay prefetch profile: ")
                     (when current-prefix-arg
                       (read-directory-name "Remote project root: "))))
  (when (or (string-empty-p name) (relay--prefetch-profile name))
    (user-error "relay: profile name is empty or already exists"))
  (relay--prefetch-ensure-profile name root)
  (setq relay--prefetch-selected-profile name)
  (relay--prefetch-config-save)
  (message "relay: created profile %s" name))

;;;###autoload
(defun relay-prefetch-activate-profile (name)
  "Add profile NAME to the active prefetch profile set."
  (interactive (list (completing-read "Activate profile: "
                                      (relay--prefetch-profile-names) nil t)))
  (unless (relay--prefetch-profile name)
    (user-error "relay: no such profile: %s" name))
  (cl-pushnew name relay--prefetch-active-profiles :test #'equal)
  (setq relay--prefetch-selected-profile name)
  (relay--prefetch-apply-active-profiles)
  (relay--prefetch-config-save)
  (message "relay: activated profile %s" name))

;;;###autoload
(defun relay-prefetch-deactivate-profile (name)
  "Remove profile NAME from the active prefetch profile set."
  (interactive (list (completing-read "Deactivate profile: "
                                      relay--prefetch-active-profiles nil t)))
  (setq relay--prefetch-active-profiles
        (delete name (copy-sequence relay--prefetch-active-profiles)))
  (relay--prefetch-apply-active-profiles)
  (relay--prefetch-config-save)
  (message "relay: deactivated profile %s" name))

;;;###autoload
(defun relay-prefetch-rename-profile (name new-name)
  "Rename profile NAME to NEW-NAME, preserving active and selected state."
  (interactive
   (list (completing-read "Rename profile: " (relay--prefetch-profile-names) nil t)
         (read-string "New profile name: ")))
  (when (or (string-empty-p new-name) (relay--prefetch-profile new-name))
    (user-error "relay: profile name is empty or already exists"))
  (let ((profile (or (relay--prefetch-profile name)
                     (user-error "relay: no such profile: %s" name))))
    (remhash name relay--prefetch-profiles)
    (relay--prefetch-profile-put new-name profile)
    (setq relay--prefetch-active-profiles
          (mapcar (lambda (candidate) (if (equal candidate name) new-name candidate))
                  relay--prefetch-active-profiles))
    (when (equal relay--prefetch-selected-profile name)
      (setq relay--prefetch-selected-profile new-name))
    (relay--prefetch-apply-active-profiles)
    (relay--prefetch-config-save)
    (message "relay: renamed profile %s to %s" name new-name)))

;;;###autoload
(defun relay-prefetch-delete-profile (name)
  "Delete profile NAME and remove its marks from the active union.

The `default' profile is retained as an empty compatibility target instead of
being deleted, so existing direct mark/unmark commands always have a home."
  (interactive (list (completing-read "Delete profile: "
                                      (relay--prefetch-profile-names) nil t)))
  (unless (relay--prefetch-profile name)
    (user-error "relay: no such profile: %s" name))
  (if (equal name "default")
      (relay--prefetch-profile-put
       "default" (list :name "default" :listing nil :content nil))
    (remhash name relay--prefetch-profiles))
  (setq relay--prefetch-active-profiles
        (delete name (copy-sequence relay--prefetch-active-profiles)))
  (when (equal relay--prefetch-selected-profile name)
    (setq relay--prefetch-selected-profile "default"))
  (relay--prefetch-apply-active-profiles)
  (relay--prefetch-config-save)
  (message "relay: deleted profile %s" name))

;;;###autoload
(defun relay-prefetch-switch-profile (name)
  "Switch to NAME as the sole active prefetch profile.

This evicts caches belonging only to the previously active profile(s), then
starts asynchronous re-warming for NAME on any already-open connections."
  (interactive (list (completing-read "Switch to profile: "
                                      (relay--prefetch-profile-names) nil t)))
  (unless (relay--prefetch-profile name)
    (user-error "relay: no such profile: %s" name))
  (setq relay--prefetch-active-profiles (list name)
        relay--prefetch-selected-profile name)
  (relay--prefetch-apply-active-profiles)
  (relay--prefetch-config-save)
  (message "relay: switched to profile %s" name))

(defcustom relay-listing-prefetch t
  "Master switch for listing prefetch (see `relay-mark-listing-prefetch').
When nil, marked directories are not proactively (re)warmed even though the
marks themselves are unaffected. Directories not explicitly marked are always
lazy-on-expand (nothing read until actually opened), matching VS Code's
Explorer model — this variable never changes that; it only gates the marked
set's proactive-warming behavior."
  :type 'boolean :group 'relay)

;; Marks (which directories) persist across sessions via
;; `relay-prefetch-config-file'; the listing cache below (actual fetched
;; data) does not -- it exists only to make a same-session reconnect cheap.
(relay--prefetch-config-load)

(defun relay--listing-prefetch-marked-p (authority localdir)
  (gethash (cons authority localdir) relay--listing-prefetch-dirs))

(defun relay--content-prefetch-marked-p (authority localdir)
  (gethash (cons authority localdir) relay--content-prefetch-dirs))

(defcustom relay-listing-prefetch-confirm-threshold 1000
  "Entry count above which `relay-mark-listing-prefetch' asks for
confirmation before marking — a directory that large means the one-shot
`readdir' marking triggers is itself a real cost, even with the no-children
model."
  :type 'integer :group 'relay)

;;;###autoload
(defun relay-mark-listing-prefetch (dir)
  "Mark DIR for listing prefetch (metadata only — see the module commentary
above `relay-listing-prefetch' for why this never extends to children).
DIR's own listing is proactively fetched/kept warm: re-warmed immediately on
invalidation (an FS-watch event touching DIR) instead of going lazy again,
and revalidated cheaply on reconnect rather than blindly re-fetched. Nothing
about DIR's children changes — mark them separately if you want the same
treatment for any of them.

If DIR itself has more than `relay-listing-prefetch-confirm-threshold'
entries, asks for confirmation first, since that one-shot fetch is itself
non-trivial at that size."
  (interactive (list (read-directory-name "Mark for listing prefetch: ")))
  (let ((p (relay--parse (expand-file-name dir))))
    (unless p (user-error "relay: not an /relay: directory: %s" dir))
    (let* ((authority (car p))
           (localdir (directory-file-name (cdr p)))
           (key (cons authority localdir))
           (conn (relay--connection authority)))
      ;; Mark first (tentatively) so the fetch below — which happens through
      ;; the normal `relay--listing' path — sees it as marked and persists
      ;; into `relay--listing-prefetch-cache' as a side effect, rather than
      ;; needing separate duplicated persist logic here.
      (relay--prefetch-profile-add-key relay--prefetch-selected-profile :listing key)
      (cl-pushnew relay--prefetch-selected-profile relay--prefetch-active-profiles
                  :test #'equal)
      (relay--prefetch-rebuild-live-marks)
      (let ((count (length (relay--listing conn localdir))))
        (if (and (> count relay-listing-prefetch-confirm-threshold)
                 (not (yes-or-no-p
                       (format "relay: %s has %d entries — mark for listing prefetch anyway? "
                               dir count))))
            (progn
              (relay--prefetch-profile-remove-key
               relay--prefetch-selected-profile :listing key)
              (relay--prefetch-rebuild-live-marks)
              (remhash key relay--listing-prefetch-cache)
              (message "relay: not marked"))
          (relay--prefetch-config-save)
          (message "relay: %s marked for listing prefetch" dir))))))

;;;###autoload
(defun relay-unmark-listing-prefetch (dir)
  "Undo `relay-mark-listing-prefetch' for DIR."
  (interactive (list (read-directory-name "Unmark listing prefetch: ")))
  (let ((p (relay--parse (expand-file-name dir))))
    (unless p (user-error "relay: not an /relay: directory: %s" dir))
    (let ((key (cons (car p) (directory-file-name (cdr p)))))
      (relay--prefetch-profile-remove-key
       relay--prefetch-selected-profile :listing key)
      (relay--prefetch-apply-active-profiles))
    (relay--prefetch-config-save)
    (message "relay: %s unmarked" dir)))

(defun relay--attrs-mtime-key (attrs)
  "(SECONDS . NSEC) from ATTRS, for exact `equal' comparison.
`mtime' alone is integer seconds; two changes inside the same second are
otherwise indistinguishable to a reconnect-revalidation comparison."
  (cons (plist-get attrs :mtime) (plist-get attrs :mtime_nsec)))

(defun relay--attrs-time (attrs)
  "Return ATTRS's mtime as a full Emacs time value, including nanoseconds."
  (let* ((time (time-convert (or (plist-get attrs :mtime) 0) 'list))
         (nsec (or (plist-get attrs :mtime_nsec) 0)))
    (setf (nth 2 time) (/ nsec 1000)
          (nth 3 time) (* (% nsec 1000) 1000))
    time))

(defun relay--dircache-evict-prefix (conn localdir)
  "Evict LOCALDIR and every cached directory nested beneath it from CONN."
  (let ((prefix (file-name-as-directory localdir)) keys)
    (maphash (lambda (dir _)
               (when (or (equal dir localdir) (string-prefix-p prefix dir))
                 (push dir keys)))
             (relay-conn-dircache conn))
    (dolist (dir keys)
      (remhash dir (relay-conn-dircache conn))
      (remhash dir (relay-conn-dircache-mtime conn)))))

(defun relay--advance-cache-epoch (conn)
  "Invalidate in-flight cache fills on CONN after a filesystem change."
  (cl-incf (relay-conn-cache-epoch conn)))

(defun relay--notify-watchers (conn localpath event)
  "Deliver EVENT for LOCALPATH to direct file-notify watches, deferred."
  (let ((authority (relay-conn-authority conn)))
    (dolist (wc (gethash localpath (relay-conn-watches conn)))
      (let* ((descriptor (car wc))
             (callback (cdr wc))
             (fnevent (list descriptor event (relay--wrap authority localpath))))
        (run-at-time 0 nil (lambda () (ignore-errors (funcall callback fnevent))))))))

(defun relay--listing-populate (conn localdir resp)
  "Given RESP (a readdir reply plist) for LOCALDIR, populate the caches and
trigger any prefetch side effects. Shared by the synchronous fetch path
(`relay--listing') and the async re-warm path
(`relay--listing-rewarm-async'), so re-warming on invalidation never has
to block — see that function for why blocking here was a real bug, not a
theoretical one."
  (let* ((entries (plist-get resp :entries))
         (self-mtime-key (relay--attrs-mtime-key (plist-get resp :self_attrs)))
         (authority (relay-conn-authority conn)))
    (puthash localdir entries (relay-conn-dircache conn))
    (puthash localdir self-mtime-key (relay-conn-dircache-mtime conn))
    (when (and relay-listing-prefetch (relay--listing-prefetch-marked-p authority localdir))
      (puthash (cons authority localdir)
               (list :entries entries :mtime-key self-mtime-key)
               relay--listing-prefetch-cache))
    (when (relay--content-prefetch-marked-p authority localdir)
      (relay--content-prefetch-warm conn localdir))
    entries))

(defun relay--readdir-stream (conn localdir chunk-fn done-fn)
  "Stream LOCALDIR's listing via the server's chunked `readdir' — see
`relay--request-stream'. CHUNK-FN is called with each intermediate
chunk's raw entry list as it arrives (existing consumers pass `#'ignore';
this exists for a future incremental consumer, e.g. progressive dired
rendering, without needing another protocol change). DONE-FN is called
once: on success, with the complete accumulated response shaped exactly
like a single unpaginated readdir reply (`:entries' and `:self_attrs'), so
every existing caller of `relay--listing' keeps working unchanged; on
failure (the directory couldn't even be opened — a single ordinary error
reply, never a stream), with that error reply passed through unmodified.
Never blocks. Shows one progress `message' if the fetch actually needed
more than one chunk — typical directories, finishing in one, stay silent."
  (let (acc (chunk-count 0))
    (relay--request-stream
     conn "readdir" (list :path localdir)
     (lambda (msg)
       (cl-incf chunk-count)
       (when (= chunk-count 1)
         (message "relay: %s is large, still listing…" localdir))
       (setq acc (nconc acc (plist-get msg :entries)))
       (funcall chunk-fn (plist-get msg :entries)))
     (lambda (msg)
       (if (not (plist-get msg :ok))
           (funcall done-fn msg)
         (setq acc (nconc acc (plist-get msg :entries)))
         (funcall done-fn (list :ok t :entries acc :self_attrs (plist-get msg :self_attrs))))))))

(defun relay--readdir-all-async (conn localdir final-callback)
  "Fetch LOCALDIR's complete listing, paging transparently over
`relay--readdir-stream'. Never blocks."
  (relay--readdir-stream conn localdir #'ignore final-callback))

(defun relay--readdir-all-sync (conn localdir)
  "Blocking wrapper around `relay--readdir-all-async', matching
`relay--request's existing block-via-`accept-process-output' style and
request-timeout deadline."
  (let (result done (deadline (+ (float-time) relay-request-timeout)))
    (let ((id (relay--readdir-all-async conn localdir
                                           (lambda (resp) (setq result resp done t)))))
      (while (not done)
        (accept-process-output (relay-conn-process conn) 0.1)
        (when (> (float-time) deadline)
          (remhash id (relay-conn-pending conn))
          (error "relay: readdir timed out")))
      (unless (plist-get result :ok)
        (error "relay: readdir: %s" (or (plist-get result :error) "unknown error")))
      result)))

(defun relay--listing (conn localdir)
  "Return cached entry list for LOCALDIR, fetching (and watching) on a miss."
  (or (gethash localdir (relay-conn-dircache conn))
      (let (entries done)
        ;; An FS event can arrive while `relay--readdir-all-sync' yields to
        ;; the process filter.  Do not install that now-stale reply; retry the
        ;; fetch against the post-event epoch instead.
        (while (not done)
          (let* ((epoch (relay-conn-cache-epoch conn))
                 (resp (relay--readdir-all-sync conn localdir)))
            (when (= epoch (relay-conn-cache-epoch conn))
              ;; The fetched listing is already usable; install freshness
              ;; tracking in the background rather than paying a second RTT.
              (relay--request-async conn "watch" (list :path localdir) #'ignore)
              (setq entries (relay--listing-populate conn localdir resp)
                    done t))))
        entries)))

(defun relay--listing-rewarm-async (conn localdir)
  "Like re-fetching LOCALDIR via `relay--listing', but never blocks — safe
to call from inside FS-event handling.

This used to just call `relay--listing' synchronously. That was a real
bug, not a theoretical one: `relay--handle-event' runs from the process
filter, which can itself be running re-entrantly inside
`accept-process-output' (e.g. a synchronous request already in flight
elsewhere). A rapid burst of FS events for one change — confirmed via a
crash, `max-lisp-eval-depth' exceeded, reproduced by writing a file through
shell redirection (truncate + write, sometimes coalesced into several
events) while its directory was content-prefetch-marked — meant each nested
event handler blocked on ANOTHER synchronous request, which re-entered
`accept-process-output', which could deliver yet another buffered event,
recursing once per buffered event instead of returning."
  (let ((epoch (relay-conn-cache-epoch conn)))
    (relay--readdir-all-async
     conn localdir
     (lambda (resp)
       (let ((key (cons (relay-conn-authority conn) localdir)))
       ;; A profile can switch while this request is in flight.  A late reply
       ;; for a deactivated-only folder must not resurrect its cache or begin
       ;; new warm work; overlapping profiles keep the key active and retain it.
       (when (and (= epoch (relay-conn-cache-epoch conn))
                  (relay--prefetch-key-active-p key))
         (if (plist-get resp :ok)
             (progn
               (remhash key relay--prefetch-problems)
               (relay--listing-populate conn localdir resp)
               (relay--request-async conn "watch" (list :path localdir) #'ignore))
           ;; Keep configured intent on absence/permission/network failures so
           ;; the user can retry when the directory returns.
           (puthash key (or (plist-get resp :error) "listing failed")
                    relay--prefetch-problems))))))))

(defun relay--rewarm-marked (conn)
  "Re-fetch every directory marked for listing OR content prefetch on CONN's
authority. Used after a coarse \"overflow\" event, where we cannot tell which
specific directories changed. (A directory marked only for content prefetch
still needs its listing re-fetched here — content prefetch depends on
knowing the current file list; `relay--listing-rewarm-async' triggers the
content warm itself for any directory that's content-marked.)

Uses `relay--listing-rewarm-async', never the synchronous `relay--listing'
— a real bug, not a theoretical one, caught by review: this is called from
`relay--handle-event's \"overflow\" branch, the same reentrancy-sensitive
process-filter context the sibling per-file event branch was already fixed
for. An overflow event is itself produced by a burst of FS events
overwhelming the watcher's queue — precisely the scenario that caused the
original `max-lisp-eval-depth' crash. A synchronous call here would have
reintroduced that exact crash class whenever overflow fires while any
directory is marked."
  (let ((authority (relay-conn-authority conn))
        (seen (make-hash-table :test 'equal)))
    ;; Listing-prefetch's own proactive re-warming is gated by its master
    ;; switch (see the matching fix in `relay--handle-event'); content-
    ;; prefetch's need for a fresh listing is independent (gated by its own
    ;; switch inside `relay--content-prefetch-warm') and always processed.
    (when relay-listing-prefetch
      (maphash (lambda (key _marked)
                 (when (and (equal (car key) authority) (not (gethash key seen)))
                   (puthash key t seen)
                   (relay--listing-rewarm-async conn (cdr key))))
               relay--listing-prefetch-dirs))
    (maphash (lambda (key _marked)
               (when (and (equal (car key) authority) (not (gethash key seen)))
                 (puthash key t seen)
                 (relay--listing-rewarm-async conn (cdr key))))
             relay--content-prefetch-dirs)))

(defun relay--revalidate-marked-on-connect (conn)
  "For each directory marked for listing OR content prefetch on CONN's
authority, reuse the persisted (survives-reconnect) listing if a cheap
`stat' shows its directory-mtime hasn't changed since we last saw it (see
`relay--listing-prefetch-cache'); otherwise fetch for real. A directory's
own mtime changes whenever an entry is added/removed/renamed within it, so
this is a reliable, much cheaper substitute for a full re-`readdir' on the
common case of \"nothing changed while disconnected\". A directory marked
only for content prefetch still needs this — content prefetch depends on
having a current listing to know which files exist — even though
`relay--listing-prefetch-cache' is only ever populated for listing-marked
directories (so a content-only directory always falls through to a real
fetch here; there's nothing persisted to reuse for it)."
  (let ((authority (relay-conn-authority conn))
        (seen (make-hash-table :test 'equal)))
    (dolist (table (list relay--listing-prefetch-dirs relay--content-prefetch-dirs))
      (maphash
       (lambda (key _marked)
         (when (and (equal (car key) authority) (not (gethash key seen)))
           (puthash key t seen)
           (let* ((localdir (cdr key))
                  (cached (gethash key relay--listing-prefetch-cache))
                  (epoch (relay-conn-cache-epoch conn)))
             ;; A reconnect must remain one handshake rather than N blocking
             ;; stats/readdirs for N marked directories.  Leave this new
             ;; connection's cache empty until an async validation succeeds,
             ;; so no unvalidated old listing can be served in the meantime.
             (if (not cached)
                 (relay--listing-rewarm-async conn localdir)
               (relay--request-async
                conn "stat" (list :path localdir)
                (lambda (resp)
                  ;; Ignore a late reconnect validation after its profile has
                  ;; been switched away; otherwise it can resurrect old cache.
                  (when (and (= epoch (relay-conn-cache-epoch conn))
                             (relay--prefetch-key-active-p key))
                    (let ((current-mtime-key
                           (and (plist-get resp :ok)
                                (relay--attrs-mtime-key (plist-get resp :attrs)))))
                      (if (and current-mtime-key
                               (equal current-mtime-key (plist-get cached :mtime-key)))
                          (progn
                            (puthash localdir (plist-get cached :entries) (relay-conn-dircache conn))
                            (puthash localdir (plist-get cached :mtime-key) (relay-conn-dircache-mtime conn))
                            ;; The watch died with the old connection too.
                            (relay--request-async conn "watch" (list :path localdir) #'ignore)
                            (when (relay--content-prefetch-marked-p authority localdir)
                              (relay--content-prefetch-warm conn localdir)))
                        (relay--listing-rewarm-async conn localdir))))))))))
       table))))

(defun relay--entry-if-cached (conn localdir name)
  "Like looking up NAME in LOCALDIR's listing, but never triggers a fresh
fetch — only consults LOCALDIR's listing if it's already cached. Used by
`relay--stat' so that statting a single file never forces a full parent
`readdir' as a side effect (see `relay--stat')."
  (let ((cached (gethash localdir (relay-conn-dircache conn))))
    (and cached (seq-find (lambda (e) (equal (plist-get e :name) name)) cached))))

(defun relay--stat (conn local)
  "Attrs plist for LOCAL.

Uses the parent directory's cached listing opportunistically — for free, if
the parent already happens to be cached from browsing it — but never
triggers a full parent `readdir' just to answer one file's stat. An earlier
version did (via a helper that would fetch-then-look-up), and it mattered:
confirmed opening one file directly in an uncached 5000-entry directory
forced a full `lstat'-every-entry sweep of the whole parent merely to check
that one file's attributes, via ordinary operations like `file-exists-p'
that Emacs runs routinely during `find-file'. Falls through to the server's
direct single-file `stat' op instead of ever doing that."
  (let* ((dir (relay--dirname local))
         (name (relay--basename local))
         (e (and (not (equal local "/"))
                 (relay--entry-if-cached conn dir name))))
    (or e (plist-get (relay--request conn "stat" :path local) :attrs))))

(defun relay--handle-event (conn msg)
  "React to an async FS event: invalidate cache and fire file-notify callbacks.
For a directory marked for listing prefetch, re-fetches it right away
instead of leaving it lazy — the whole point of marking is to keep it
instantly available, so an invalidated mark shouldn't silently degrade to
\"fetched only on next visit\" until something else happens to evict it.

Re-warming uses `relay--listing-rewarm-async', never the synchronous
`relay--listing' — this function runs from the process filter, which can
itself be running re-entrantly inside `accept-process-output', and a
synchronous request here previously caused unbounded reentrant nesting
during a burst of FS events (confirmed via a real crash, `max-lisp-eval-depth'
exceeded)."
  (let ((event (plist-get msg :event))
        (authority (relay-conn-authority conn)))
    ;; Every FS event wins over all older outstanding listing/revalidation
    ;; replies, including delete/rename events whose replies race in later.
    (relay--advance-cache-epoch conn)
    (cond
     ((equal event "overflow")
      (clrhash (relay-conn-dircache conn)) ; coarse: re-enumerate on next access
      (clrhash (relay-conn-dircache-mtime conn))
      (relay--content-cache-evict-authority authority)
      (relay--rewarm-marked conn))
     ;; The watched directory ITSELF was renamed or deleted — reported using
     ;; its own alias directly (:dir here, no :name), which the agent
     ;; resolved via its own alias table, so there's no canonical-vs-alias
     ;; mismatch to reconcile on this side. Drop everything cached under it,
     ;; same as a delete. See `relay--listing-rewarm-async's sibling note
     ;; in server/src/main.rs for why the ordinary dir/name event shape
     ;; can't represent this case: the parent here may have no registered
     ;; alias at all if we never watched it, only this directory itself.
     ((equal event "self_changed")
      (let ((localdir (plist-get msg :dir)))
        (relay--dircache-evict-prefix conn localdir)
        (remhash (cons authority localdir) relay--listing-prefetch-cache)
        (relay--content-cache-evict-prefix authority localdir)
        (relay--notify-watchers conn localdir 'changed)))
     (t
      (let* ((dir (plist-get msg :dir))
             (name (plist-get msg :name))
             (localpath (concat (file-name-as-directory dir) name)))
        (remhash dir (relay-conn-dircache conn)) ; drop stale listing -> next access refetches
        (remhash dir (relay-conn-dircache-mtime conn))
        ;; NAME may be a directory; clear its cached descendants too.  This
        ;; is harmless for a file and prevents stale trees after rename/delete.
        (relay--dircache-evict-prefix conn localpath)
        ;; Content-cache correctness, not just freshness: a stale cached copy
        ;; of a file that just changed (or vanished) on disk must never keep
        ;; being served. Evict unconditionally — a harmless no-op if this
        ;; path was never content-cached — independent of whether this
        ;; directory happens to be content-prefetch-marked.
        (relay--content-cache-evict-prefix authority localpath)
        ;; `relay-listing-prefetch' is documented as gating whether marked
        ;; directories are proactively (re)warmed at all — review caught
        ;; that it was only actually checked at one persistence-bookkeeping
        ;; site, not here, so turning it off didn't stop proactive
        ;; re-fetching as its own docstring promises. Content-prefetch's
        ;; need for a fresh listing is independent (gated by its own master
        ;; switch inside `relay--content-prefetch-warm') and must still
        ;; trigger a re-fetch regardless of the listing switch.
        (when (or (and relay-listing-prefetch (relay--listing-prefetch-marked-p authority dir))
                  (relay--content-prefetch-marked-p authority dir))
          (relay--listing-rewarm-async conn dir))
        (dolist (wc (gethash dir (relay-conn-watches conn)))
          (let* ((descriptor (car wc)) (callback (cdr wc))
                 (fnevent (list descriptor
                                (pcase event ("created" 'created) ("removed" 'deleted)
                                       (_ 'changed))
                                (concat (file-name-as-directory
                                         (format "/relay:%s:%s" authority dir))
                                        name))))
            ;; Deferred, not called synchronously here — review flagged that
            ;; a third-party callback (`auto-revert-mode', dired's own
            ;; file-notify hooks — code we don't control) could itself do
            ;; blocking I/O in response to this notification (e.g.
            ;; auto-revert reverting the buffer, which stats/reads the
            ;; file), reintroducing the exact reentrant-recursion crash
            ;; class this round of fixes targeted, one level removed:
            ;; relay's own code no longer blocks here, but a callback it
            ;; invokes still could. `run-at-time' with a 0 delay runs the
            ;; callback on the next turn of the command loop instead of
            ;; immediately, outside the process filter's reentrant context
            ;; entirely, so even a blocking callback can no longer nest
            ;; inside an in-flight `accept-process-output' call.
            (run-at-time 0 nil (lambda () (ignore-errors (funcall callback fnevent)))))))))))


(provide 'relay-prefetch)
;;; relay-prefetch.el ends here

;;; relay-file-handler.el --- File-name handler for relay -*- lexical-binding: t; -*-

;;; Code:

(require 'relay-core)
(require 'relay-prefetch)
(require 'relay-content-prefetch)
(require 'relay-completion)
(require 'relay-conflict)

;;;; ---------------------------------------------------------------------------
;;;; Attribute conversion

(defun relay--mode-string (mode kind)
  (let ((s (make-string 10 ?-)) (perms "rwxrwxrwx"))
    (aset s 0 (cond ((equal kind "dir") ?d) ((equal kind "symlink") ?l) (t ?-)))
    (dotimes (i 9)
      (when (/= 0 (logand mode (ash 1 (- 8 i))))
        (aset s (1+ i) (aref perms i))))
    s))

(defun relay--attrs->file-attributes (attrs)
  "Convert our ATTRS plist into an Emacs `file-attributes' list."
  (when attrs
    (let* ((kind (plist-get attrs :kind))
           (size (or (plist-get attrs :size) 0))
           ;; `time-convert' (a core C primitive, never autoloaded) instead of
           ;; `seconds-to-time' (elisp, lives in `time-date.el', NOT preloaded):
           ;; the first-ever call to an autoloaded function from within a
           ;; handler op — while `default-directory' is one of our /relay:
           ;; paths — corrupted the library's own absolute path (see the
           ;; `expand-file-name' journal entry). Simplest fix is to just not
           ;; trigger an autoload here at all.
           (mtime (relay--attrs-time attrs))
           (mode (or (plist-get attrs :mode) 0)))
      (list (cond ((equal kind "dir") t)
                  ((equal kind "symlink") (or (plist-get attrs :target) t))
                  (t nil))
            1 0 0 mtime mtime mtime size
            (relay--mode-string mode kind) t 0 0))))

;;;; ---------------------------------------------------------------------------
;;;; file-name-handler operations

(defconst relay--probe-name "/relay:probe:/x"
  "A representative /relay: name, used to find handlers that would claim ours.")

(defun relay--claiming-handlers ()
  "Handlers in `file-name-handler-alist' that would claim an /relay: name."
  (let (res)
    (dolist (cell file-name-handler-alist (nreverse res))
      (when (and (stringp (car cell))
                 (string-match-p (car cell) relay--probe-name))
        (push (cdr cell) res)))))

(defun relay--run-real (operation args)
  "Run OPERATION with ARGS on a possibly-wrapped name, with rival handlers off.

Inhibiting only our own handler is not enough: Emacs would walk on to the next
matching entry, TRAMP would claim the `/relay:' name, parse `relay' as a
method, and signal \"Method `relay' is not known\".  Worse, that merely
*touching* TRAMP autoloads it, and `tramp-register-file-name-handlers'
prepends itself ahead of us — so one leaked op sends every subsequent op to
TRAMP.  Inhibit every claiming handler so the primitive runs its real C
implementation."
  (let ((inhibit-file-name-handlers
         (append (relay--claiming-handlers)
                 (and (eq inhibit-file-name-operation operation)
                      inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))
    (apply operation args)))

(defun relay--remote-home-localname-p (localname)
  "Non-nil when LOCALNAME is the remote account's `~' shorthand."
  (or (equal localname "~") (string-prefix-p "~/" localname)))

(defun relay--normalize-remote-home-localname (localname)
  "Normalize LOCALNAME while preserving its remote-home `~' prefix.

The real `expand-file-name' must not see the leading tilde: it would expand it
against the machine running Emacs.  A synthetic root lets it still collapse
ordinary `.' and `..' components.  If the path climbs above the remote home,
keep the original spelling; only the server knows the home directory's parent."
  (if (equal localname "~")
      "~"
    (let* ((marker "/__relay_remote_home__")
           (expanded (relay--run-real
                      'expand-file-name
                      (list (concat marker (substring localname 1)) "/"))))
      (cond ((equal expanded marker) "~")
            ((string-prefix-p (concat marker "/") expanded)
             (concat "~" (substring expanded (length marker))))
            (t localname)))))

(defun relay--h-expand-file-name (name &optional dir)
  "Matches TRAMP's own observed behavior, verified empirically, not assumed:
evaluating `expand-file-name' on an absolute name with default-directory
bound to a TRAMP path returns the plain local name unchanged, not a
remote-wrapped one.  So an already-absolute NAME ignores DIR entirely here
too, matching real Unix `expand-file-name' semantics and contradicting the
common assumption that a remote default-directory makes bare absolute paths
inherit the remote host.

This distinction is not academic: the wrap-everything version of this
function corrupted Emacs's own Lisp autoloading.  `dired-noselect' calls the
autoloaded `dired-goto-subdir' on first use, and `load' resolves that
library's absolute path via `expand-file-name' using whatever
default-directory happens to be — inside a dired buffer for one of our
/relay: dirs, that is exactly this handler.  Wrapping turned the real path
to dired-aux.el into a bogus remote one, so every `dired-noselect' on a fresh
Emacs process failed.  Confirmed with a minimal repro: binding
default-directory to an /relay: name and calling `(load \"dired-aux\")'
fails with the wrap-everything version and succeeds with this one; the
identical repro against a real TRAMP directory succeeds either way, which is
what let this go unnoticed at first."
  (setq dir (or dir default-directory))
  (let ((p (relay--parse name)))
    (cond
     (p (relay--wrap
         (car p)
         (if (relay--remote-home-localname-p (cdr p))
             (relay--normalize-remote-home-localname (cdr p))
           (relay--run-real 'expand-file-name (list (cdr p) "/")))))
     ;; `file-name-absolute-p' also covers `~'/`~user'-led names — checked
     ;; against real TRAMP too: `(let ((default-directory "/ssh:host:/home/x/"))
     ;; (expand-file-name "~/foo"))' resolves against the *local* home, not the
     ;; remote one, same as a plain "/..." name. One check covers both.
     ((file-name-absolute-p name)
      (relay--run-real 'expand-file-name (list name "/")))
     ((relay--parse dir)
      (let ((pd (relay--parse dir)))
        (relay--wrap
         (car pd)
         (if (relay--remote-home-localname-p (cdr pd))
             (relay--normalize-remote-home-localname
              (concat (file-name-as-directory (cdr pd)) name))
           (relay--run-real 'expand-file-name (list name (cdr pd)))))))
     (t (relay--run-real 'expand-file-name (list name dir))))))

(defun relay--h-file-attributes (filename &optional _id-format)
  (let ((p (relay--parse filename)))
    (when p (relay--attrs->file-attributes
             (relay--stat (relay--connection (car p)) (cdr p))))))

(defun relay--h-file-exists-p (filename)
  (let ((p (relay--parse filename)))
    (and p (relay--stat (relay--connection (car p)) (cdr p)) t)))

(defun relay--h-file-directory-p (filename)
  (let ((p (relay--parse filename)))
    (and p (equal "dir" (plist-get (relay--stat (relay--connection (car p))
                                               (cdr p)) :kind)))))

(defun relay--h-file-regular-p (filename)
  (let ((p (relay--parse filename)))
    (and p (equal "file" (plist-get (relay--stat (relay--connection (car p))
                                                (cdr p)) :kind)))))

(defun relay--h-file-symlink-p (filename)
  (let ((p (relay--parse filename)))
    (when p
      (let ((a (relay--stat (relay--connection (car p)) (cdr p))))
        (and (equal "symlink" (plist-get a :kind)) (or (plist-get a :target) t))))))

(defun relay--h-file-readable-p (filename) (relay--h-file-exists-p filename))
(defun relay--h-file-writable-p (filename)
  (let ((p (relay--parse filename)))
    (and p (or (relay--h-file-exists-p filename)
               (relay--h-file-exists-p
                (relay--wrap (car p) (relay--dirname (cdr p))))))))

(defun relay--h-directory-files (directory &optional full match nosort _count)
  (let* ((p (relay--parse directory))
         (conn (relay--connection (car p)))
         (names (mapcar (lambda (e) (plist-get e :name))
                        (relay--listing conn (directory-file-name (cdr p))))))
    (setq names (append '("." "..") names))
    (when match (setq names (seq-filter (lambda (n) (string-match-p match n)) names)))
    (unless nosort (setq names (sort names #'string<)))
    (if full (mapcar (lambda (n) (concat (file-name-as-directory directory) n)) names) names)))

(defun relay--completion-arguments (file directory)
  "Return `(AUTHORITY LOCALDIR PARTIAL)' for a completion handler call."
  (if-let ((parsed (relay--parse directory)))
      (list (car parsed) (directory-file-name (cdr parsed)) file)
    (when-let ((parsed (relay--parse file)))
      (let ((local (cdr parsed)))
        (list (car parsed) (relay--dirname local) (relay--basename local))))))

(defun relay--h-file-name-all-completions (file directory)
  (let* ((args (or (relay--completion-arguments file directory)
                   (error "relay: no remote completion path in %S / %S" file directory)))
         (authority (nth 0 args)) (localdir (nth 1 args)) (partial (nth 2 args))
         (entries (relay--listing (relay--connection authority) localdir)) res)
    (dolist (e entries res)
      (let ((name (plist-get e :name)))
        (when (string-prefix-p partial name)
          (push (if (equal (plist-get e :kind) "dir") (concat name "/") name) res))))))

(defun relay--h-file-name-completion (file directory &optional predicate)
  (try-completion file (mapcar #'list (relay--h-file-name-all-completions file directory))
                  ;; `try-completion' hands PREDICATE a one-element entry,
                  ;; whereas `file-name-completion' predicates such as
                  ;; `file-exists-p' expect a file-name string.  Match
                  ;; TRAMP's calling convention by expanding the entry first.
                  (when predicate
                    (lambda (entry) (funcall predicate
                                           (expand-file-name (car entry) directory))))))

(defun relay--h-insert-directory (file switches &optional wildcard full-directory-p)
  "Best-effort dired listing (M0): emit ls-l-ish lines from cached attrs."
  (ignore wildcard)
  (let* ((p (relay--parse file)) (conn (relay--connection (car p)))
         (localdir (directory-file-name (cdr p))))
    (if (not full-directory-p)
        ;; Single-file line. Dired takes this branch (rather than the
        ;; full-directory one below) for cases like reverting a buffer
        ;; whose own directory has vanished out from under it — confirmed
        ;; by testing a rename of a currently-open dired buffer's
        ;; directory. `relay--stat' returning nil means the path
        ;; genuinely doesn't exist; signal that plainly instead of quietly
        ;; building a garbage line from a nil attrs plist (all-zero size,
        ;; epoch mtime — this is what actually happened before this fix:
        ;; a real, reproduced bug, not a hypothetical). Plain local dired's
        ;; equivalent situation produces a clear `file-missing' error (from
        ;; `insert-directory's own `ls' subprocess failing to start in a
        ;; vanished directory) — match that shape rather than fabricating
        ;; fake data.
        (let ((a (relay--stat conn (cdr p))))
          (unless a (signal 'file-missing (list "Reading directory" "No such file or directory" file)))
          (insert (relay--ls-line (relay--basename (cdr p)) a) "\n"))
      (let ((entries (sort (copy-sequence (relay--listing conn localdir))
                           (lambda (a b) (string< (plist-get a :name) (plist-get b :name))))))
        (when (string-match-p "a" (or switches "")) (insert "  total 0\n"))
        (dolist (e entries) (insert (relay--ls-line (plist-get e :name) e) "\n"))))))

(defun relay--ls-line (name attrs)
  (let ((mode (relay--mode-string (or (plist-get attrs :mode) 0) (plist-get attrs :kind)))
        (size (or (plist-get attrs :size) 0))
        ;; `format-time-string' accepts a raw epoch number directly — no
        ;; `seconds-to-time' conversion (and its autoload) needed at all.
        (time (format-time-string "%b %e %H:%M" (or (plist-get attrs :mtime) 0))))
    (format "  %s %2d %-8s %-8s %8d %s %s" mode 1 "user" "group" size time name)))

(defun relay--configure-auto-revert-for-current-buffer ()
  "Permit enabled Auto-Revert modes to act in a relay file buffer."
  (when (and buffer-file-name (relay--parse buffer-file-name))
    (setq-local auto-revert-remote-files t)
    ;; `find-file' creates a new empty buffer without calling our insert
    ;; handler when the path is absent.  Give that visited new-file buffer an
    ;; explicit missing BASE so its first save remains create-only.
    (when (and (not relay-conflict--base)
               (not (relay--h-file-exists-p buffer-file-name)))
      (relay-conflict--install-buffer "" (list :schema 1 :state "missing") 'utf-8))))

(defun relay--h-insert-file-contents (filename &optional visit beg end replace)
  (if (and beg end)
      ;; Range reads are deliberately uncached and never establish BASE:
      ;; callers use them for bounded transcript tails/history, not visits.
      (let* ((p (relay--parse filename))
             (conn (relay--connection (car p)))
             (hello (relay-conn-hello conn))
             (reply (if (member "read-range-v1" (plist-get hello :capabilities))
                        (relay--request conn "read_range" :path (cdr p)
                                        :start beg :end end)
                      ;; Compatibility with an older revisions-v1 server.
                      ;; This fallback is intentionally bounded by the old
                      ;; server's normal read limit; new servers are required
                      ;; for large-file range access.
                      (let* ((full (relay--request conn "read" :path (cdr p)))
                             (all (base64-decode-string (plist-get full :bytes_b64))))
                        (list :bytes_b64
                              (base64-encode-string
                               (substring all (min beg (length all))
                                          (min end (length all))) t)))))
             (bytes (base64-decode-string (plist-get reply :bytes_b64)))
             (text (decode-coding-string bytes 'utf-8)))
        (when replace (erase-buffer))
        (insert text)
        (list filename (length text)))
    (let* ((p (relay--parse filename)) (conn (relay--connection (car p)))
         (entry (relay--content-cache-get-entry (car p) (cdr p)))
         ;; Never establish BASE from an old cache entry that has no revision.
         ;; Reverts must always fetch a fresh revision; only initial opens may
         ;; reuse bytes paired with their exact cached revision.
         (cached (and (not replace) entry
                      (or (not visit) (plist-get entry :revision)) entry))
         (reply (unless cached
                  (condition-case err
                      (relay--request conn "read" :path (cdr p))
                    (relay-request-error
                     ;; Visiting a nonexistent path creates an explicit
                     ;; missing BASE, so its first ordinary save is still a
                     ;; server-enforced create-only conditional write.
                     (let ((wire (nth 2 err)))
                       (if (and visit (not replace)
                                (string-match-p "[Nn]o such\\|not found"
                                                (or (plist-get wire :error) "")))
                           (list :ok t :missing t)
                         (signal (car err) (cdr err))))))))
         (bytes (or (plist-get cached :bytes)
                    (if (plist-get reply :missing) ""
                      (base64-decode-string (plist-get reply :bytes_b64)))))
         (revision (or (plist-get cached :revision) (plist-get reply :revision)
                       (and (plist-get reply :missing) (list :schema 1 :state "missing")))))
    (when replace (erase-buffer))
    (let ((text (decode-coding-string bytes 'utf-8))) ; M0: assume utf-8
      (insert text)
      (when visit
        (setq buffer-file-name filename)
        (set-visited-file-modtime)
        (set-buffer-modified-p nil)
        (relay-conflict--install-buffer bytes revision 'utf-8))
      ;; Some callers build a second visited buffer explicitly by inserting
      ;; first and assigning `buffer-file-name' afterwards.  Preserve the
      ;; stable read snapshot until that later save can claim it; this does
      ;; not install a handler or alter an unrelated unvisited buffer.
      (unless visit
        (setq-local relay-conflict--pending-read
                    (list :filename filename :bytes bytes :revision revision)))
      (list filename (length text))))))

(defun relay--h-write-region (start end filename &optional append visit _lock mustbenew)
  ;; APPEND can be t, nil, or an integer offset (rare, e.g. rewriting from a
  ;; midpoint); M0 only distinguishes t/non-nil vs nil, matching the common
  ;; append-to-file / auto-save-append cases.
  (let* ((p (relay--parse filename)) (conn (relay--connection (car p)))
         (text (if (stringp start) start
                 (buffer-substring-no-properties (or start (point-min))
                                                 (or end (point-max)))))
         (b64 (base64-encode-string (encode-coding-string text 'utf-8) t)))
    (relay--request conn "write" :path (cdr p) :bytes_b64 b64
                      :append (relay--bool append)
                      :must_be_new (relay--bool mustbenew))
    (remhash (relay--dirname (cdr p)) (relay-conn-dircache conn)) ; new file shows up
    ;; Keep the content cache correct rather than just dropping it: we
    ;; already have the freshly-written bytes in memory, so update in place
    ;; instead of forcing a wasted re-fetch on the next open. Only meaningful
    ;; for non-append writes -- appending would need the OLD bytes we don't
    ;; have here, so just evict rather than cache something wrong.
    (if append
        (relay--content-cache-evict (cons (car p) (cdr p)))
      (when (relay--content-cache-get (car p) (cdr p))
        (relay--content-cache-put (car p) (cdr p)
                                    (encode-coding-string text 'utf-8))))
    (when (or (eq visit t) (stringp visit))
      (set-visited-file-modtime) (set-buffer-modified-p nil))
    (unless visit (message "Wrote %s" filename))))

(defun relay--h-file-truename (filename)
  (let ((p (relay--parse filename)))
    (if (not p) (relay--run-real 'file-truename (list filename))
      (condition-case nil
          (relay--wrap (car p)
                          (plist-get (relay--request (relay--connection (car p))
                                                       "resolve" :path (cdr p)) :realpath))
        (error filename)))))

(defun relay--h-file-remote-p (file &optional identification _connected)
  (let ((p (relay--parse file)))
    (when p
      (pcase identification
        ('method "relay") ('host (car p)) ('localname (cdr p)) ('user nil)
        (_ (format "/relay:%s:" (car p)))))))

(defun relay--h-file-local-copy (filename)
  "Copy remote FILENAME to a local temp file; return its name."
  (let* ((p (relay--parse filename)) (conn (relay--connection (car p)))
         (bytes (base64-decode-string
                 (plist-get (relay--request conn "read" :path (cdr p)) :bytes_b64)))
         (tmp (make-temp-file "relay-")))
    (let ((coding-system-for-write 'binary))
      (with-temp-file tmp (set-buffer-multibyte nil) (insert bytes)))
    tmp))

(defun relay--h-file-notify-add-watch (file _flags callback)
  (let* ((p (relay--parse file)) (authority (car p)) (conn (relay--connection authority))
         (localdir (directory-file-name (cdr p))))
    ;; Do not manufacture a descriptor if the server rejected the OS watch.
    ;; Auto-Revert wraps this operation in `ignore-errors'; a real error makes
    ;; it retain a nil descriptor and use its polling fallback when configured.
    (relay--request conn "watch" :path localdir)
    ;; Registered in `relay--direct-watches' (authority-keyed, not tied to
    ;; CONN) so this watch survives a reconnect -- see
    ;; `relay--rewatch-direct-on-connect'.
    (relay--direct-watch-add authority localdir callback)))

(defun relay--h-file-notify-rm-watch (descriptor)
  "Review caught that this never told the server to `unwatch' at all —
every watch added via `file-notify-add-watch' (dired, `auto-revert-mode')
leaked its OS-level watch handle for the life of the connection, with no
bound on how many could accumulate over a long session.

Fixed, but carefully: only send `unwatch' for a directory whose local
file-notify watcher list just became empty AND that isn't ALSO watched for
our own reasons independent of file-notify — `relay--listing' et al watch
directories for dircache freshness with no unwatch trigger of their own by
design (cached directories stay watched for the connection's lifetime).
Unwatching a directory that's still cached would silently break that
cache's freshness guarantee for browsing, so only unwatch when the
directory isn't currently cached either."
  (let* ((authority (car descriptor))
         (emptied-key (relay--direct-watch-remove descriptor))
         (conn (and emptied-key (gethash authority relay--connections))))
    ;; No live connection for this authority means nothing to tell the
    ;; server to unwatch on -- a reconnect never re-registers a directory
    ;; this call already removed from `relay--direct-watches'.
    (when (and emptied-key conn (process-live-p (relay-conn-process conn)))
      (let ((localdir (cdr emptied-key)))
        (unless (gethash localdir (relay-conn-dircache conn))
          (relay--request-async conn "unwatch" (list :path localdir) #'ignore))))))

;;;; ---------------------------------------------------------------------------
;;;; Mutation operations

(defun relay--invalidate (conn local)
  "Drop the cached listing holding LOCAL, so a mutation is visible immediately.
Freshness is a headline goal (ARCHITECTURE §8): our own writes must never be
the thing that makes the cache lie.

Also evicts any content-cache entries for LOCAL itself or nested under it
(`relay--content-cache-evict-prefix' handles both a plain file path and a
directory path correctly — it degenerates to an exact-key match when
there's nothing nested under it). Review caught that this function only
ever touched the listing cache: overwriting a content-prefetched file via
`copy-file'/`rename-file', or deleting and recreating one, left the content
cache's stale bytes in place, silently served on the next open — the same
\"our own write must never make the cache lie\" principle this function's
own docstring already states, just not applied to both caches."
  (relay--advance-cache-epoch conn)
  (remhash (relay--dirname local) (relay-conn-dircache conn))
  (remhash (relay--dirname local) (relay-conn-dircache-mtime conn))
  (relay--dircache-evict-prefix conn local)
  (relay--content-cache-evict-prefix (relay-conn-authority conn) local))

(defun relay--bool (x) (if x t :false))

(defun relay--h-directory-files-and-attributes
    (directory &optional full match nosort id-format count)
  (ignore id-format)
  (let* ((p (relay--parse directory)) (conn (relay--connection (car p)))
         (localdir (directory-file-name (cdr p))))
    (mapcar (lambda (name)
              (let ((local (concat (file-name-as-directory localdir)
                                   (file-name-nondirectory name))))
                (cons name (relay--attrs->file-attributes (relay--stat conn local)))))
            (relay--h-directory-files directory full match nosort count))))

(defun relay--h-make-directory (dir &optional parents)
  (let* ((p (relay--parse dir)) (conn (relay--connection (car p)))
         (local (directory-file-name (cdr p))))
    (relay--request conn "mkdir" :path local :parents (relay--bool parents))
    (relay--invalidate conn local) nil))

(defun relay--h-delete-directory (dir &optional recursive _trash)
  ;; No remote trash in M0: deleting means deleting.  Say so rather than
  ;; pretending, so nobody relies on a recoverable delete that isn't.
  (let* ((p (relay--parse dir)) (conn (relay--connection (car p)))
         (local (directory-file-name (cdr p))))
    (relay--request conn "rmdir" :path local :recursive (relay--bool recursive))
    (relay--invalidate conn local) (remhash local (relay-conn-dircache conn)) nil))

(defun relay--h-delete-file (filename &optional _trash)
  (let* ((p (relay--parse filename)) (conn (relay--connection (car p))))
    (relay--request conn "delete" :path (cdr p))
    (relay--invalidate conn (cdr p)) nil))

(defun relay--h-copy-file (file newname &optional ok-if-exists _keep-time
                                  _preserve-uid-gid _preserve-perms)
  (relay--transfer "copy" file newname ok-if-exists))

(defun relay--h-rename-file (file newname &optional ok-if-exists)
  (relay--transfer "rename" file newname ok-if-exists))

(defun relay--transfer (op file newname ok-if-exists)
  "Run server OP (copy/rename) from FILE to NEWNAME.
Both must live on the same authority: a cross-authority or remote<->local
transfer needs a staging path, which M0 does not do.  Erroring is the honest
answer — silently copying to a literal `/relay:…' local path is how
`delete-file' previously appeared to succeed while doing nothing."
  (let ((src (relay--parse file)) (dst (relay--parse newname)))
    (cond ((not (and src dst))
           (error "relay: %s between remote and local names is not supported in M0" op))
          ((not (equal (car src) (car dst)))
           (error "relay: %s across authorities (%s -> %s) is not supported in M0"
                  op (car src) (car dst)))
          (t (let ((conn (relay--connection (car src))))
               (relay--request conn op :path (cdr src) :to (cdr dst)
                                 :ok_if_exists (relay--bool ok-if-exists))
               (relay--invalidate conn (cdr src))
               (relay--invalidate conn (cdr dst)) nil)))))

(defun relay--h-get-file-buffer (filename)
  "Buffer-list scan, no I/O — safe to implement directly rather than via
`relay--run-real', since the real primitive would just re-enter file name
handler dispatch for `expand-file-name' anyway."
  (let ((exp (expand-file-name filename)))
    (seq-find (lambda (buf) (equal (buffer-local-value 'buffer-file-name buf) exp))
              (buffer-list))))

(defun relay--h-file-newer-than-file-p (file1 file2)
  ;; Go through the *generic* `file-attributes', not our internal stat cache
  ;; directly, so a comparison between a remote and a local name (or two
  ;; different authorities) dispatches each side correctly.
  (let ((a1 (file-attributes file1)) (a2 (file-attributes file2)))
    (cond ((not a1) nil) ((not a2) t)
          (t (time-less-p (file-attribute-modification-time a2)
                          (file-attribute-modification-time a1))))))

(defun relay--h-set-visited-file-modtime (&optional time-list)
  "Dispatched with NO filename arg — it always targets `current-buffer'.

An earlier version of this gave up and fell through to the real primitive
unmodified, which stats the literal `/relay:…' string as a local path
(always fails) and records the `visited-file-modtime' sentinel 0
(\"unknown\"). That was defended at the time as merely degrading
`ask-user-about-supersession-threat' to a no-op — true, but it turned out
to break something bigger: `verify-visited-file-modtime' special-cases that
exact sentinel and returns t (\"unchanged\") WITHOUT ever dispatching to a
handler — confirmed empirically (a first probe against a buffer stuck at
the sentinel never reached our dispatcher; the identical call against a
buffer with a real recorded time DID reach it, as
`relay--h-verify-visited-file-modtime' below). That silently broke
`auto-revert-mode': its own notify watch fires correctly (confirmed
directly), but `buffer-stale--default-function' — which
`auto-revert-handler' consults before reverting — computes `(not
(verify-visited-file-modtime ...))', so an eternally \"unknown\" recorded
time reads as eternally \"unchanged\", and the buffer never reverts despite
a real, correctly-detected external change.

Fix: when TIME-LIST is nil (\"use the file's actual current mtime\", the
common case — this is what `find-file'/`save-buffer' pass), fetch our own
remote stat and call the real primitive with that time given EXPLICITLY.
Passing an explicit time avoids the primitive ever needing to stat anything
itself, so there's no bogus local path in this path at all. When TIME-LIST
is already given explicitly (the caller supplying its own value), it needs
no remote information; run-real handles that directly."
  (if time-list
      (relay--run-real 'set-visited-file-modtime (list time-list))
    (let* ((p (and buffer-file-name (relay--parse buffer-file-name)))
           (attrs (and p (relay--stat (relay--connection (car p)) (cdr p)))))
      (relay--run-real 'set-visited-file-modtime
                         (list (and attrs (relay--attrs-time attrs)))))))

(defun relay--h-verify-visited-file-modtime (buffer)
  "Dispatched with BUFFER (not a filename) — confirmed empirically, same
calling convention as `set-visited-file-modtime'. Only reached at all when
BUFFER's recorded `visited-file-modtime' is a real value, not the
\"unknown\" sentinel (see `relay--h-set-visited-file-modtime'); Emacs
short-circuits to t before ever dispatching in the sentinel case."
  (with-current-buffer buffer
    (let ((p (and buffer-file-name (relay--parse buffer-file-name))))
      (if (not p) t
        ;; A modified revision-aware buffer must reach its conditional write
        ;; handler.  The generic Emacs stale prompt is weaker and would offer
        ;; a misleading unconditional "save anyway" before our conflict menu.
        (if (and relay-conflict--base (buffer-modified-p))
            t
          (let ((attrs (ignore-errors
                         (relay--stat (relay--connection (car p)) (cdr p)))))
            (and attrs (plist-get attrs :mtime)
                 (equal (relay--attrs-time attrs) (visited-file-modtime)))))))))

(defun relay--h-find-backup-file-name (_fn)
  ;; No backups for remote files in M0 (see docs/TESTING.md's scope table).
  ;; nil is the documented "don't make a backup" answer, not a stand-in error.
  nil)

(defun relay--h-make-auto-save-file-name ()
  "Return the ordinary transformed auto-save name for the current buffer.

`make-auto-save-file-name' dispatches with no filename argument; it reads
`buffer-file-name' instead. Run the real implementation with remote handlers
inhibited so `auto-save-file-name-transforms' can map the complete relay name
to a collision-safe local file, just as it does for other remote names."
  (relay--run-real 'make-auto-save-file-name nil))

(defun relay--h-dired-uncache (dir)
  "Drop DIR from our directory-listing cache, so the fetch immediately
following (dired's own `dired-readin') is guaranteed fresh instead of a
stale cache hit. Dispatched with DIR as the sole argument — confirmed from
dired.el's real source: `dired-uncache' is a plain function, not a
special-dispatch primitive like `set-visited-file-modtime', and it just does
`(funcall handler \\='dired-uncache dir)' when a handler exists.

This is NOT a rename/delete edge case — `dired-revert' calls `dired-uncache'
unconditionally on every single revert (`g'), so leaving this unimplemented
made ordinary dired refresh error out every time, independent of whether
anything had actually changed. Found while checking what happens when a
dired buffer's own directory gets renamed out from under it; turned out to
be a much more basic, session-wide gap than that specific scenario."
  (let ((p (relay--parse dir)))
    (when p
      (let* ((conn (relay--connection (car p)))
             (local (directory-file-name (cdr p))))
        (remhash local (relay-conn-dircache conn))
        (remhash local (relay-conn-dircache-mtime conn))))))

(defun relay--h-file-modes (filename &optional _flag)
  (let ((p (relay--parse filename)))
    (when p (plist-get (relay--stat (relay--connection (car p)) (cdr p)) :mode))))

;; File locking (the `.#filename' advisory-lock mechanism) needs a symlink
;; primitive the server doesn't have in M0.  No-op rather than erroring: like
;; backups, this is a documented scope cut, and unlike `delete-file' silently
;; not deleting, a skipped lock does not corrupt or mask any state — it only
;; loses the concurrent-edit warning.
(defun relay--h-lock-file (_file) nil)
(defun relay--h-unlock-file (_file) nil)
(defun relay--h-file-locked-p (_file) nil)
(defun relay--h-vc-registered (_file)
  ;; VC integration is a later milestone (it needs `process-file', M1).  nil
  ;; ("not under version control") is the honest answer for now, not a stand-in.
  nil)
(defun relay--h-file-system-info (_filename)
  ;; M0 has no statvfs-equivalent server op.  nil is a documented, valid
  ;; answer ("if the underlying system call fails") — not a lie, unlike
  ;; letting this fall through to a local statvfs on a bogus wrapped path.
  nil)

(defun relay--h-unsupported (op &rest _)
  (error "relay: `%s' is not supported in Milestone 0 (remote exec is M1)" op))

(defconst relay--handlers
  `((expand-file-name . relay--h-expand-file-name)
    (file-attributes . relay--h-file-attributes)
    (file-exists-p . relay--h-file-exists-p)
    (file-directory-p . relay--h-file-directory-p)
    (file-regular-p . relay--h-file-regular-p)
    (file-symlink-p . relay--h-file-symlink-p)
    (file-readable-p . relay--h-file-readable-p)
    (file-writable-p . relay--h-file-writable-p)
    (directory-files . relay--h-directory-files)
    (file-name-all-completions . relay--h-file-name-all-completions)
    (file-name-completion . relay--h-file-name-completion)
    (insert-directory . relay--h-insert-directory)
    (insert-file-contents . relay--h-insert-file-contents)
    (write-region . relay--h-write-region)
    (file-truename . relay--h-file-truename)
    (file-remote-p . relay--h-file-remote-p)
    (file-local-copy . relay--h-file-local-copy)
    (file-notify-add-watch . relay--h-file-notify-add-watch)
    (file-notify-rm-watch . relay--h-file-notify-rm-watch)
    (directory-files-and-attributes . relay--h-directory-files-and-attributes)
    (make-directory . relay--h-make-directory)
    (delete-directory . relay--h-delete-directory)
    (delete-file . relay--h-delete-file)
    (copy-file . relay--h-copy-file)
    (rename-file . relay--h-rename-file)
    (get-file-buffer . relay--h-get-file-buffer)
    (file-newer-than-file-p . relay--h-file-newer-than-file-p)
    (file-system-info . relay--h-file-system-info)
    (set-visited-file-modtime . relay--h-set-visited-file-modtime)
    (verify-visited-file-modtime . relay--h-verify-visited-file-modtime)
    (find-backup-file-name . relay--h-find-backup-file-name)
    (make-auto-save-file-name . relay--h-make-auto-save-file-name)
    (dired-uncache . relay--h-dired-uncache)
    (file-modes . relay--h-file-modes)
    (lock-file . relay--h-lock-file)
    (unlock-file . relay--h-unlock-file)
    (file-locked-p . relay--h-file-locked-p)
    (vc-registered . relay--h-vc-registered)
    (process-file . ,(apply-partially #'relay--h-unsupported 'process-file))
    (start-file-process . ,(apply-partially #'relay--h-unsupported 'start-file-process))
    (shell-command . ,(apply-partially #'relay--h-unsupported 'shell-command)))
  "Operation -> handler function.  See `relay--pure-path-ops' for the rest.")

(defconst relay--pure-path-ops
  '(directory-file-name file-name-as-directory file-name-directory
    file-name-nondirectory file-name-sans-versions unhandled-file-name-directory
    abbreviate-file-name substitute-in-file-name file-name-case-insensitive-p)
  "Operations that are pure string manipulation on the file name.
These need no round trip: a wrapped `/relay:auth:/path' name manipulates
exactly like any absolute Unix path, so the real C implementation gives the
right answer — provided every rival handler is inhibited (see
`relay--run-real'), which is why they are enumerated rather than reached by
a catch-all.")

;;;###autoload
(defun relay-file-name-handler (operation &rest args)
  "Dispatch OPERATION for /relay: file names.

Unknown operations deliberately signal instead of falling through to the local
implementation.  A catch-all fallthrough is not a safe default here: the local
primitive would run against the literal string `/relay:auth:/path', which is
a *valid relative-to-nothing local path*, so I/O ops fail silently or hit the
wrong file rather than erroring.  That is exactly how `delete-file' once
returned nil (\"success\") while the target file remained on disk."
  (let ((filename (car args)) (fn (cdr (assq operation relay--handlers))))
    (cond
     ((memq operation relay--pure-path-ops) (relay--run-real operation args))
     ((and (stringp filename) (string-prefix-p "/relay:" filename)
           (not (relay--parse filename)))
      (cond ((eq operation 'expand-file-name) filename)
            ((memq operation '(file-exists-p file-directory-p file-regular-p
                              file-readable-p file-writable-p file-symlink-p
                              file-attributes)) nil)
            (t (user-error "relay: incomplete path; press TAB for ssh+ and a host, or use /relay:ssh+HOST:/path"))))
     (fn (apply fn args))
     (t (error "relay: operation `%s' is not implemented yet (Milestone 0)" operation)))))

;;;###autoload
(defun relay-register ()
  "Install relay's remote-path handler and minibuffer completion advice."
  (relay-clear-ssh-host-cache)
  (add-hook 'find-file-hook #'relay--configure-auto-revert-for-current-buffer)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer (relay--configure-auto-revert-for-current-buffer)))
  (setq file-name-handler-alist
        (cons (cons "\\`/relay:" #'relay-file-name-handler)
              (rassq-delete-all 'relay-completion-file-name-handler
                                (rassq-delete-all #'relay-file-name-handler
                                                  file-name-handler-alist))))
  (advice-remove 'file-name-all-completions #'relay--advice-file-name-all-completions)
  (advice-remove 'file-name-completion #'relay--advice-file-name-completion)
  (advice-remove 'read-file-name-internal 'relay--advice-read-file-name-internal)
  (advice-remove 'completion-all-completions #'relay--advice-completion-all-completions)
  (advice-add 'file-name-all-completions :around #'relay--advice-file-name-all-completions)
  (advice-add 'file-name-completion :around #'relay--advice-file-name-completion)
  (advice-add 'completion-all-completions :around #'relay--advice-completion-all-completions))

;;;###autoload
(progn
  (relay-register)
  (with-eval-after-load 'tramp
    (let ((ours "\\`/relay:") (cur (bound-and-true-p tramp-ignored-file-name-regexp)))
      (unless (and cur (string-search ours cur))
        (setq tramp-ignored-file-name-regexp
              (if (and cur (not (string-empty-p cur))) (concat "\\(?:" cur "\\)\\|" ours) ours))))
    (relay-register)))

;;;; ---------------------------------------------------------------------------
;;;; Smoke test

(defun relay-smoke-test (dir)
  "Connect via `local' and exercise the RPC core against DIR."
  (interactive "DSmoke-test dir: ")
  (let* ((conn (relay--connection "local")) (hello (relay-conn-hello conn))
         (entries (plist-get (relay--request conn "readdir" :path (expand-file-name dir))
                             :entries))
         (nested (when entries (relay--request conn "stat"
                                                :path (expand-file-name
                                                       (plist-get (car entries) :name) dir)))))
    (let ((msg (format "server=%s os=%s entries=%d nested-ok=%s"
                       (plist-get hello :server_version) (plist-get hello :os)
                       (length entries) (and nested (plist-get nested :ok)))))
      (when (called-interactively-p 'any) (message "%s" msg)) msg)))

(provide 'relay-file-handler)
;;; relay-file-handler.el ends here

;;; relay-content-prefetch.el --- Content prefetch for relay -*- lexical-binding: t; -*-

;;; Code:

(require 'relay-prefetch)

;;;; Content prefetch (file BYTES, not just listings) — a separate, more
;;;; dangerous mechanism from listing prefetch above, off by default, never
;;;; implied by it. A directory marked for content prefetch also needs its
;;;; listing kept warm (to know which files exist), so marking it keeps the
;;;; listing-prefetch machinery running for that directory as a side effect
;;;; — a one-way dependency, not a violation of "independently controlled":
;;;; listing-prefetch on its own still never triggers content-prefetch.

(defcustom relay-content-prefetch nil
  "Master switch for content prefetch (see `relay-mark-content-prefetch').
Off by default — deliberately more conservative than listing prefetch, since
this proactively reads file BYTES, not just metadata."
  :type 'boolean :group 'relay)

(defcustom relay-content-prefetch-extensions '("json" "txt" "py" "md")
  "Files eligible for content prefetch, matched two ways against each entry
in a content-prefetch-marked directory: by extension (case-insensitively,
without the leading dot — e.g. \"json\"), or by exact filename, for files
worth prefetching that don't have a conventional extension (e.g.
\"Makefile\", \"Dockerfile\"). Add entries either way as needed."
  :type '(repeat string) :group 'relay)

(defcustom relay-content-prefetch-max-file-size (* 50 1024)
  "Files larger than this (bytes) are never content-prefetched, regardless of
extension — content prefetch is the more dangerous of the two mechanisms, so
this defaults conservatively small."
  :type 'integer :group 'relay)

(defcustom relay-content-prefetch-lru-size 50
  "Maximum number of files' content kept warm across ALL directories marked
for content prefetch, combined — a *global* budget, not per-directory (see
`relay-content-prefetch-per-dir-limit' for that one). Least-recently-used
content is evicted first once this is exceeded."
  :type 'integer :group 'relay)

(defcustom relay-content-prefetch-per-dir-limit 10
  "Maximum number of files' content kept warm from any ONE directory marked
for content prefetch, regardless of the global
`relay-content-prefetch-lru-size' budget. Without this, one marked
directory with many qualifying files could consume the entire global budget
before any other marked directory gets a chance."
  :type 'integer :group 'relay)

(defvar relay--content-cache (make-hash-table :test 'equal)
  "(AUTHORITY . LOCALPATH) -> file content (a unibyte string), for
content-prefetched files. NOT persisted across Emacs sessions or reconnects —
purely a runtime performance cache, always safe to refetch on demand.")

(defvar relay--content-cache-order nil
  "List of (AUTHORITY . LOCALPATH) keys in `relay--content-cache', most
recently used first. Kept in sync by `relay--content-cache-put'/-get.")

(defvar relay--content-cache-revisions (make-hash-table :test 'equal)
  "(AUTHORITY . LOCALPATH) -> revision returned with cached content.")

(defun relay--content-cache-dir-count (authority localdir)
  (let ((prefix (file-name-as-directory localdir)))
    (cl-count-if (lambda (key)
                   (and (equal (car key) authority)
                        (string-prefix-p prefix (cdr key))))
                 relay--content-cache-order)))

(defun relay--content-cache-evict (key)
  (remhash key relay--content-cache)
  (remhash key relay--content-cache-revisions)
  (setq relay--content-cache-order (delete key relay--content-cache-order)))

(defun relay--content-cache-evict-prefix (authority localdir)
  "Evict every content-cache entry for AUTHORITY whose path is LOCALDIR
itself or nested under it. Used when a whole directory vanishes or is
renamed out from under us — see `relay--handle-event'."
  (let ((prefix (file-name-as-directory localdir)))
    (dolist (key (copy-sequence relay--content-cache-order))
      (when (and (equal (car key) authority)
                 (or (equal (cdr key) localdir) (string-prefix-p prefix (cdr key))))
        (relay--content-cache-evict key)))))

(defun relay--content-cache-evict-authority (authority)
  "Evict every content-cache entry for AUTHORITY, regardless of path.
Used on a coarse \"overflow\" event, where we cannot tell which specific
files changed — review caught that the overflow branch cleared the listing
cache but left the content cache untouched, so any content-prefetched file
that actually changed during the burst that triggered the overflow would
keep being served from stale cached bytes indefinitely (content-prefetch-
warm skips re-fetching anything already present in the cache, so nothing
would ever correct this on its own)."
  (dolist (key (copy-sequence relay--content-cache-order))
    (when (equal (car key) authority)
      (relay--content-cache-evict key))))

(defun relay--content-cache-put (authority localpath bytes &optional revision)
  "Insert BYTES for (AUTHORITY . LOCALPATH), enforcing both the per-directory
and global caps by evicting least-recently-used entries as needed."
  (let* ((key (cons authority localpath))
         (localdir (relay--dirname localpath)))
    (puthash key bytes relay--content-cache)
    (if revision
        (puthash key revision relay--content-cache-revisions)
      (remhash key relay--content-cache-revisions))
    (setq relay--content-cache-order (cons key (delete key relay--content-cache-order)))
    ;; Per-directory cap: evict this same directory's least-recently-used
    ;; entries first — `reverse' walks oldest-to-newest so the first match
    ;; found is the oldest one. The `victim' guard in the loop condition
    ;; itself (rather than a mid-loop early return) stops this safely if the
    ;; count and the matching logic ever disagree — should not happen, but
    ;; an infinite loop is a worse failure mode than silently stopping.
    (let ((victim t))
      (while (and victim
                  (> (relay--content-cache-dir-count authority localdir)
                     relay-content-prefetch-per-dir-limit))
        (setq victim (seq-find (lambda (k) (and (equal (car k) authority)
                                                (equal (relay--dirname (cdr k)) localdir)))
                               (reverse relay--content-cache-order)))
        (when victim (relay--content-cache-evict victim))))
    ;; Global cap: evict the overall least-recently-used entry.
    (while (> (length relay--content-cache-order) relay-content-prefetch-lru-size)
      (relay--content-cache-evict (car (last relay--content-cache-order))))))

(defun relay--content-cache-get (authority localpath)
  (let* ((key (cons authority localpath))
         (v (gethash key relay--content-cache)))
    (when v
      (setq relay--content-cache-order (cons key (delete key relay--content-cache-order))))
    v))

(defun relay--content-cache-get-entry (authority localpath)
  "Return cached bytes and their revision, or nil if no entry exists."
  (let ((bytes (relay--content-cache-get authority localpath)))
    (when bytes
      (list :bytes bytes
            :revision (gethash (cons authority localpath)
                               relay--content-cache-revisions)))))

(defun relay--content-prefetch-eligible-p (entry)
  "Non-nil if ENTRY (a readdir entry plist) qualifies for content prefetch: a
file, under the size cap, and matching `relay-content-prefetch-extensions'
either by extension or exact filename."
  (and (equal (plist-get entry :kind) "file")
       (<= (or (plist-get entry :size) 0) relay-content-prefetch-max-file-size)
       (let* ((name (plist-get entry :name))
              (ext (file-name-extension name)))
         (or (and ext (member (downcase ext)
                              (mapcar #'downcase relay-content-prefetch-extensions)))
             (member name relay-content-prefetch-extensions)))))

(defun relay--content-prefetch-warm (conn localdir)
  "Asynchronously fetch content for eligible files in LOCALDIR's
already-cached listing, up to whatever's left of this directory's
`relay-content-prefetch-per-dir-limit' budget. Only called for
directories marked via `relay-mark-content-prefetch' (directly, or via
re-warm/reconnect paths).

Deliberately budget-limited rather than firing one request per eligible
file: a directory with thousands of small eligible files (plausible — the
whole point of the extension allowlist is files like .py/.md/.json, which
real trees have a lot of) would otherwise fire thousands of concurrent async
reads even though nearly all of them would just get evicted immediately by
the per-directory cap anyway. No point paying for work whose result can't
survive."
  (when relay-content-prefetch
    (let* ((authority (relay-conn-authority conn))
           (already (relay--content-cache-dir-count authority localdir))
           (budget (max 0 (- relay-content-prefetch-per-dir-limit already)))
           (eligible (seq-filter #'relay--content-prefetch-eligible-p
                                 (gethash localdir (relay-conn-dircache conn)))))
      (dolist (e (seq-take eligible budget))
        (let* ((name (plist-get e :name))
               (localpath (concat (file-name-as-directory localdir) name)))
          (unless (relay--content-cache-get authority localpath)
            (relay--request-async
             conn "read" (list :path localpath)
             (lambda (resp)
               ;; A failed read (e.g. the file was deleted between listing
               ;; and this fetch actually landing) is silently dropped, not
               ;; an error -- the next real open just does a normal fetch
               ;; and surfaces whatever's actually true then.
               (when (plist-get resp :ok)
                 (relay--content-cache-put
                 authority localpath
                  (base64-decode-string (plist-get resp :bytes_b64))
                  (plist-get resp :revision)))))))))))

(defcustom relay-content-prefetch-confirm-threshold 200
  "Eligible-file count above which `relay-mark-content-prefetch' asks for
confirmation before marking — proactively reading many files' content, even
small ones, is real work and real network traffic."
  :type 'integer :group 'relay)

;;;###autoload
(defun relay-mark-content-prefetch (dir)
  "Mark DIR for content prefetch: eligible files inside it (see
`relay-content-prefetch-extensions'/`relay-content-prefetch-max-file-size')
have their BYTES proactively fetched and kept warm in a bounded LRU cache
(`relay-content-prefetch-lru-size' global,
`relay-content-prefetch-per-dir-limit' per directory), so opening them is
instant. A separate, more deliberate opt-in than
`relay-mark-listing-prefetch' — does not require marking DIR for listing
prefetch first, but DIR's listing is kept warm as a side effect (needed to
know which files even exist); that dependency runs only one way.

If more than `relay-content-prefetch-confirm-threshold' files in DIR are
eligible, asks for confirmation first."
  (interactive (list (read-directory-name "Mark for content prefetch: ")))
  (let ((p (relay--parse (expand-file-name dir))))
    (unless p (user-error "relay: not an /relay: directory: %s" dir))
    (let* ((authority (car p))
           (localdir (directory-file-name (cdr p)))
           (key (cons authority localdir))
           (conn (relay--connection authority))
           (entries (relay--listing conn localdir))
           (eligible (seq-filter #'relay--content-prefetch-eligible-p entries)))
      (if (and (> (length eligible) relay-content-prefetch-confirm-threshold)
               (not (yes-or-no-p
                     (format "relay: %s has %d eligible files — mark for content prefetch anyway? "
                             dir (length eligible)))))
          (message "relay: not marked")
        (relay--prefetch-profile-add-key
         relay--prefetch-selected-profile :content key)
        (cl-pushnew relay--prefetch-selected-profile relay--prefetch-active-profiles
                    :test #'equal)
        (relay--prefetch-rebuild-live-marks)
        (relay--prefetch-config-save)
        (relay--content-prefetch-warm conn localdir)
        (message "relay: %s marked for content prefetch (%d eligible files)"
                 dir (length eligible))))))

;;;###autoload
(defun relay-unmark-content-prefetch (dir)
  "Undo `relay-mark-content-prefetch' for DIR. Does not evict already-cached
content for files in DIR — it simply ages out of the LRU normally."
  (interactive (list (read-directory-name "Unmark content prefetch: ")))
  (let ((p (relay--parse (expand-file-name dir))))
    (unless p (user-error "relay: not an /relay: directory: %s" dir))
    (relay--prefetch-profile-remove-key
     relay--prefetch-selected-profile :content
     (cons (car p) (directory-file-name (cdr p))))
    (relay--prefetch-apply-active-profiles)
    (relay--prefetch-config-save)
    (message "relay: %s unmarked" dir)))

(provide 'relay-content-prefetch)
;;; relay-content-prefetch.el ends here

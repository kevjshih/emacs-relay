# Testing Milestone 0

> Status: M0 is implemented. It has been exercised over real SSH to a Linux
> host, and locally (no-SSH transport) on macOS — not yet over real SSH to a
> macOS host. Start with the low-level smoke test — it validates the part that
> matters most (the reentrancy-safe RPC core) independently of the handler layer.

## Prerequisites

- **Rust 1.85+** (the server uses edition 2024; older toolchains: set `edition =
  "2021"` in `server/Cargo.toml`).
- **Emacs 28+** (uses `json-parse-string`, `string-search`).
- A Unix remote (Linux/macOS) reachable via your `ssh` (the server uses Unix stat).
- For `scripts/install-server.sh`: Rustup; and, for Linux targets, the matching
  musl cross linker (Homebrew's `musl-cross` on macOS). The script installs a
  missing Rust target automatically.

## 1. Build the server

```sh
cd server
cargo build --release
# binary at: server/target/release/relay-server
```

## 2. Low-level smoke test (local transport, no ssh) — validate the RPC core

This exercises transport + framing + the **reentrancy-safe request/response** core
against your local filesystem, bypassing ssh and most handler complexity.

```elisp
(add-to-list 'load-path "~/src/relay/lisp")
(require 'relay)
(setq relay-server-local-path "~/src/relay/server/target/release/relay-server")

(relay-smoke-test "/tmp")
;; => "server=0.0.1 os=macos entries=N nested-ok=t"
```

`nested-ok=t` means a nested request issued mid-reply resolved correctly — i.e. the
reentrancy handling works. **This passing is the M0 de-risk milestone.**

## 3. SSH test — the real transport

The transport shells out to your system `ssh`, so `~/.ssh/config` (Host aliases,
`ProxyJump`, `IdentityFile`, `ControlMaster`, …) applies unchanged. `DEST` in
`/relay:ssh+DEST:/path` is whatever you'd type after `ssh`.

1. Install the matching server binary (one command per host):

   ```sh
   scripts/install-server.sh DEST
   ```

   This installs `~/.cache/relay/relay-server`, which is the default
   `relay-server-remote-path`; no Emacs customization is needed.

2. Browse / open / save:

   ```
   C-x C-f /relay:ssh+DEST:/etc/hostname     RET      ; open a file
   C-x C-f /relay:ssh+DEST:/var/log/         TAB      ; completion (browsing)
   C-x d   /relay:ssh+DEST:/home/you/        RET      ; dired (best-effort in M0)
   ```

3. **Freshness check** (the headline): open a dir in Emacs, then from a separate
   shell on the remote `touch /that/dir/newfile`. With dired auto-revert on, or on
   the next visit, it should appear within ~1 round-trip.

## What works / what to expect

| Area | State |
|---|---|
| RPC core (id-matched, reentrancy-safe) | implemented and exercised |
| `readdir`/`stat`/`resolve`/`read`/`write`/`watch` | implemented |
| find-file completion (browsing) | implemented (cache-backed) |
| open + async interactive revision-safe save + local transformed auto-save | implemented for regular UTF-8 files ≤16 MiB |
| dired (`insert-directory`, including revert) | implemented |
| file-notify / freshness | implemented (invalidate + deferred callback; coarse on overflow) |
| `relay-exec-raw` / `relay-exec-text` (synchronous, argv-only, bounded output) | implemented |
| `process-file`/`start-file-process` (streaming, async, interactive processes) / magit / grep | **not supported** (Milestone 1) |
| binary merges, final symlinks, hardlinks, FIFOs/directories, large files | rejected for revision-safe replacement |

## Revision-safe save checks

The client and server must be installed as a matching protocol-v1 pair.  The
hello reply must include `revisions-v1`; otherwise Emacs reports that the server
needs reinstalling.  For a local verification run, first build the server, then
run the Rust and focused ERT suites from the repository root:

```sh
(cd server && cargo build --offline && cargo test --offline)
/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q -L lisp -L test \
  -l test/relay-tests.el -f ert-run-tests-batch-and-exit
/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q -L lisp -L test \
  -l test/relay-conflict-tests.el -f ert-run-tests-batch-and-exit
/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q -L lisp -L test \
  -l test/relay-save-tests.el -f ert-run-tests-batch-and-exit
/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q -L lisp -L test \
  -l test/relay-exec-tests.el -f ert-run-tests-batch-and-exit
/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q -L lisp \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile lisp/*.el test/*.el
bash -n scripts/install-server.sh
git diff --check
```

The conflict suite covers BASE/LOCAL/REMOTE classification, synchronous
compatibility writes, conflict choices, Ediff snapshots, Auto-Revert, server
capability rejection, and transport ambiguity. The async save suite covers
immediate return and pending state, hook timing, exact-snapshot success, edits,
renames and killed buffers during flight, delayed visible success, latest-only
coalescing and revision ordering, queue cancellation, every conflict class,
lost-reply reconciliation without blind retry, async resolution writes, and
confirmed-only Ediff closure. Current local green counts are Rust 40/40, core
ERT 67/67, conflict ERT 47/47, async-save ERT 27/27, and exec ERT 16/16.

For a manual local-server check, visit one tiny regular UTF-8 fixture in two
buffers.  Save an edit in the first, then save a distinct edit in the second:
`C-x C-s` must return while the modified marker and `Saving…` lighter remain;
the second save must show the conflict banner rather than overwrite. Press
`C-x C-s` again to open the resolution menu. Test an
external edit with Auto-Revert both enabled and disabled; a clean buffer may
reload only when enabled, while a dirty buffer stays untouched and conflicts on
save.  Test remote deletion separately: a dirty visited buffer must not silently
recreate it.  Choose Keep Local and Keep Remote once each, and use Merge once;
the latter must open Ediff over independent LOCAL, REMOTE, and BASE snapshots.

Do not treat a notification as proof of correctness.  Disable Auto-Revert or
miss a notification entirely and repeat the stale save: the server's revision
check must still reject it.  If a write loses its transport reply, do not retry
blindly; reconnect and let relay classify REMOTE against intended LOCAL and
BASE.

No real-host validation is recorded here.  Controlled remote validation, when
authorized, should use uniquely named tiny `/tmp` fixtures, remove all fixtures
and recovery artifacts, and confirm no stale server processes remain.

## Reporting back

Note in `JOURNAL.md` what passed/failed (especially the smoke test result and any
handler ops that errored during real `find-file`/`dired`), so we can iterate.

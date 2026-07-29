# Relay

A thin local GUI Emacs attached to a remote dev host, giving you instant local
editing and TRAMP-like file browsing with less per-operation latency than
TRAMP.

> **Status: Milestone 0 implemented, plus a small synchronous exec primitive.**
> The async `/relay:` file layer — browse, open, edit, save, dired, freshness
> via FS watch, directory/content prefetch, streaming listings for large
> directories — is working, tested over real SSH to a Linux host, and
> exercised locally (no-SSH transport) on macOS. Alongside that, `relay-exec-raw`
> (see [Usage](#running-a-command-remotely) below) runs one argv command on
> the remote host and blocks for its exit code plus captured stdout/stderr —
> deliberately not the same thing as real `process-file`/`start-file-process`
> support (no streaming stdin/stdout, no async sentinels, no long-running
> interactive processes), which remains **not implemented**, along with
> remote LSP/search/git/build integration and local tree-sitter syntax
> (mentioned below as design direction). See
> [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the full design and roadmap
> beyond M0 — treat it as a design plan, not a feature list.

**Scope note:** this is a personal project, built for the author's own
workflow, not a general-purpose TRAMP replacement aiming for broad
compatibility or an audience beyond that. Used and shared as-is, at your own
risk — no support commitment, no warranty (see [`LICENSE`](./LICENSE)). If
you want something more broadly featured and actively maintained for a wider
range of use cases, see
[emacs-tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc) in
[Prior art](#prior-art) below.

## Why

Emacs already has two good ways to work on remote code, each a real tradeoff:

- **TRAMP** keeps a native local GUI, and pays a network round-trip on every
  file/LSP operation in exchange — synchronous calls can pause the editor.
- **Remote daemon + terminal `emacsclient`** gets zero latency to the code,
  in exchange for the GUI.

Relay builds on TRAMP's magic-file-name approach: same idea (a native local
GUI, remote files addressed through Emacs's own handler mechanism), aiming for
less per-operation latency by keeping a persistent connection instead of
paying a fresh round-trip per operation. Today that covers file browsing,
editing, and saving — not LSP, search, git, or build, which still need TRAMP
or a remote shell for now.

## The idea in one picture

```
  LOCAL (laptop)            REMOTE (dev host)
  thin GUI Emacs (the "UI") <===>  Rust relay-server
  - instant local editing   ssh    - FS watch (freshness)
  - /relay: file handler    pipe   - readdir/stat/read/write
                                   - revision-safe conditional writes
```

- **Typing is instant** — you edit a local buffer; nothing round-trips.
- **Browsing is TRAMP-like but fast** — the remote serves directory listings over a
  persistent channel with a local cache and push-based invalidation.
- **Saves are conflict-safe** — a revision token guards every write, so a stale
  save never silently overwrites a change it didn't see (see below).

## Key design decisions

- **Path model:** remote files are addressed as `/relay:TYPE+HOST:/path` via our
  own `file-name-handler-alist` entry (a sibling to TRAMP, not a TRAMP method).
  TRAMP is demoted to bootstrapping the remote. `TYPE` is structured to leave
  room for other transports later, but **`ssh` is the only one implemented
  today** (plus a `local` transport used only for no-SSH testing).
- **Execution boundary:** we distinguish *local execution with remote I/O* (the
  default) from *remote execution* (only where chattiness demands it) — because,
  unlike VS Code extensions, **Emacs packages paint in-process**.
- **Language engine:** syntactic tier (tree-sitter) runs local; semantic tier (LSP
  server) runs remote next to the code. LSP **client** placement is the key open
  question — see `ARCHITECTURE.md` §9.
- **Native engine:** the hot paths (cache/VFS, tree enumeration + fuzzy index,
  diff/delta, transport) are **Rust**, as a sidecar process and/or dynamic module;
  thin Elisp shims sit on the interactive path.

## Install

### Prerequisites

- **Emacs 28+** (uses `json-parse-string`, `string-search`).
- **Rust 1.85+** to build the server (the server uses edition 2024; an older
  toolchain can set `edition = "2021"` in `server/Cargo.toml` instead).
- A Unix remote host (Linux or macOS) reachable via your normal `ssh`.
- To let `scripts/install-server.sh` cross-compile for you: **Rustup**, and for
  Linux targets, a matching musl cross linker (for example, Homebrew's
  `musl-cross` on macOS). The script installs any missing Rust target
  automatically.

### 1. Install the Elisp package

This is currently a checkout-based Emacs package: clone this repository somewhere
stable, then load its `lisp/` directory from your init file. Add the following,
adjusting the path to your checkout:

```elisp
(add-to-list 'load-path "~/src/relay/lisp")
(require 'relay)
```

`require` registers the `/relay:` file-name handler for the Emacs session. No
TRAMP method or `~/.ssh/config` change is required; relay invokes your normal
system `ssh`, so existing host aliases, keys, `ProxyJump`, and ControlMaster setup
continue to apply (see [SSH configuration](#4-ssh-configuration) below).

### 2. Build the server binary

The server is the Rust binary that runs on each remote host and speaks the
framed JSON protocol over stdio. To build it for your **local** machine's own
architecture:

```sh
cd server
cargo build --release
# binary at: server/target/release/relay-server
```

A local build is what you want for the `local` transport (`relay-server-local-path`,
used for no-SSH smoke testing — see [`docs/TESTING.md`](./docs/TESTING.md) — and
for any other caller that connects via `local`, e.g. `relay-exec-raw`/`relay-exec-text`
run against this machine) and for development. To get a binary that runs on a **different** host's OS/CPU
architecture, use the cross-compiling install script in the next step instead of
a plain `cargo build`.

### 3. Install the server on a remote host

**Automated (recommended)** — one command per host, run from the repository
checkout:

```sh
scripts/install-server.sh HOST
```

`HOST` is anything `ssh` accepts (an alias from `~/.ssh/config` is recommended).
The script: asks the host for its OS/architecture over SSH, cross-compiles a
matching binary locally (installing the Rust target if needed), and `scp`s it
into place with an atomic rename. It detects Linux x86_64/ARM64 and macOS Apple
Silicon/Intel hosts and installs the binary at `~/.cache/relay/relay-server` —
the default `relay-server-remote-path`, so no further Emacs configuration is
needed. Re-run this command any time you update the server source or pull a new
version of this repository.

**Manual** — if you'd rather build directly on the remote host (no local
cross-compilation toolchain needed there):

```sh
# on the remote host, with a Rust 1.85+ toolchain installed:
cd server && cargo build --release
mkdir -p ~/.cache/relay
cp target/release/relay-server ~/.cache/relay/relay-server
```

Either way, the installed binary is **not a daemon or listener**. Each relay
connection starts one server process through SSH and keeps it for that
connection's lifetime. Closing or losing the SSH channel terminates that server
immediately, including when an in-flight filesystem operation is blocked;
reconnecting starts a fresh process.

### 4. SSH configuration

No relay-specific SSH configuration is required. Relay shells out to your
system `ssh` for both connecting and installing the server, so any
`~/.ssh/config` you already have just works unchanged — `DEST` in
`/relay:ssh+DEST:/path` is exactly what you'd type after `ssh DEST`.

Example `~/.ssh/config` entry:

```
Host devbox
    HostName dev.example.com
    User alice
    IdentityFile ~/.ssh/id_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h:%p
    ControlPersist 10m
```

With that in place, `/relay:ssh+devbox:/path` connects through it — including
`ProxyJump`, key selection, and any other OpenSSH directive.
`ControlMaster`/`ControlPersist` are optional but recommended: they let a
second `ssh` (for example, running `scripts/install-server.sh` again later)
reuse an already-authenticated connection instead of paying a fresh handshake.

Relay's own SSH invocation is customizable:

| Variable | Default | Purpose |
|---|---|---|
| `relay-ssh-executable` | `"ssh"` | Program used to reach remote hosts |
| `relay-ssh-extra-args` | `nil` | Extra args passed to `ssh` before the destination; leave `nil` to let `~/.ssh/config` fully govern the connection |
| `relay-ssh-connect-timeout` | `5` | Seconds passed to OpenSSH as `ConnectTimeout` (one attempt); set to `nil` to defer entirely to `~/.ssh/config` |
| `relay-connect-timeout` | `8.0` | Total seconds allowed for SSH startup plus the protocol hello reply |

An unreachable target does not wait for the general 30-second RPC deadline:
relay asks OpenSSH for one connection attempt bounded by
`relay-ssh-connect-timeout`, stops as soon as SSH exits, and reports SSH's
stderr (for example, `Could not resolve hostname` or `Connection refused`).

## Usage

### Opening and browsing remote files

```
C-x C-f /relay:ssh+HOST:/path/to/file  RET
C-x d   /relay:ssh+HOST:/path/to/dir/  RET
```

Tab-completion works at every step: `/relay:` `TAB` offers known transports;
`/relay:ssh+` `TAB` offers host aliases discovered from `~/.ssh/config` and
`~/.ssh/known_hosts` (cached — after editing those files, run
`M-x relay-clear-ssh-host-cache`).

Visited remote buffers use Emacs's normal auto-save transforms. With the
default configuration, auto-save files stay in the local temporary directory
and include the full remote authority/path to avoid basename collisions.
Enable `M-x auto-revert-mode` in a visited buffer to follow server-side edits.
Relay permits push-driven reverts only in its own buffers, leaving Emacs's
global remote-file polling setting unchanged. Unsaved local edits are not
silently overwritten.

### Conflict-safe remote saves

Visited-file saves use protocol v1 and require the server capability
`revisions-v1`. A client refuses an older server with an actionable reinstall
message instead of falling back to an unconditional overwrite. Each successful
read and conditional write carries a revision token; the server verifies that
token while holding its mutation lock and atomically replaces only the expected
regular file.

Relay retains three byte snapshots for a visited file: **BASE** (the last
successfully opened, reloaded, or saved revision), **LOCAL** (the current Emacs
buffer), and **REMOTE** (a fresh server read). A stale save never silently wins.
Remote-only changes can be adopted, convergent LOCAL/REMOTE contents are accepted
without a merge, and divergent versions enter a conflict workflow:

```
[l] Keep Local  [r] Keep Remote  [b] Restore Base
[m] Merge       [s] Save Local As… [q] Cancel
```

Whole-file choices remain conditional on the fetched REMOTE revision. Discarded
versions are retained in visible read-only recovery buffers. `Merge` runs
three-way Ediff over independent LOCAL, REMOTE, and BASE snapshots; `C-c C-c`
applies its result only if neither the live buffer nor REMOTE changed meanwhile,
and `C-c C-k` leaves the conflict unresolved.

File notifications and Auto-Revert affect when a remote edit is shown, not save
correctness. With Auto-Revert enabled, a clean buffer reloads a changed REMOTE
and advances BASE; a dirty buffer is left untouched and the next save performs
the same conditional check. With it disabled, no automatic read occurs and the
next save still detects the conflict. A remote deletion is never silently
recreated from a dirty buffer.

After a transport failure during a write, relay never retries blindly. On a
fresh connection it compares REMOTE with intended LOCAL and BASE: matching LOCAL
is treated as saved, matching BASE leaves an explicit retry available, and any
third version becomes a normal conflict. A failed reconnection reports an
uncertain save while preserving both BASE and LOCAL.

The first revision-safe release supports regular UTF-8 files up to 16 MiB.
Binary files, final symlinks, hard-linked files, directories/FIFOs and other
non-regular files are rejected for conditional replacement rather than risking a
destructive write.

### Running a command remotely

```elisp
(relay-exec-text "ssh+HOST" '("tmux" "list-panes" "-a"))
;; => (:exit-code 0 :stdout "...\n" :stderr "")
```

`relay-exec-raw` runs one command on the server side and blocks until it exits
(or times out), returning a plist of `:exit-code`, `:stdout`, and `:stderr`.
The output values are exact unibyte strings. `relay-exec-text` is the
UTF-8-decoding convenience wrapper for text commands. Both APIs cap combined
captured output at 8 MiB; they are not a general-purpose file-transfer API.
COMMAND is always an argv list — the program name, then its arguments — and
is never interpreted through a shell on either end; there is no way to pass
a shell string through this function. An optional third argument sets the
remote working directory, and an optional fourth overrides how long the
command may run before being killed (the client's own wait is extended to
match, so a generous timeout doesn't just produce a premature client-side
error instead of the server's own clear message).

This requires a server advertising the `exec-v1` capability — reinstall via
`scripts/install-server.sh` (below) if an older server errors with a
capability-mismatch message. It's a small, deliberately synchronous
primitive (see the status note at the top of this document) — reach for it
for short, well-defined commands, not anything that needs to stream output
or run indefinitely. If the client times out or disconnects, the server kills
the command's process group; malformed options and output over 8 MiB are
rejected explicitly.

### Content-prefetch profiles

Content prefetch is deliberately opt-in: it reads eligible small source/text files
from marked folders into a bounded local cache. Enable it only for projects where
you want that tradeoff:

```elisp
(setq relay-content-prefetch t)
```

Run `M-x relay-prefetch-dired`, choose an `/relay:` project directory, and use
normal Dired navigation. `C-c C-p` toggles content prefetch for the current or
Dired-marked directories; marked folders show a `●`. Create a profile rooted at
the current directory with `C-c C-n`, or switch to a profile with `C-c C-s`.
`C-c C-r` renames and `C-c C-k` deletes profiles. If a folder in a switched-in
profile no longer exists (or is temporarily inaccessible), switching still
completes: the folder remains saved as intent, the Dired header reports it as
unavailable, `C-c C-e` shows the error, and `C-c C-t` retries it after it returns.

Profiles are persisted in `relay-prefetch-config-file` (by default
`~/.emacs.d/relay-prefetch.el`). The active profile set is restored across Emacs
sessions. To avoid warming unrelated projects, use `M-x relay-prefetch-switch-profile`
when changing projects; it replaces the active marks and drops cache entries that
belonged only to the prior profile. Existing single-list configuration is migrated
automatically to a `default` profile on its next load/save.

### Customization reference

| Variable | Default | Purpose |
|---|---|---|
| `relay-server-remote-path` | `"~/.cache/relay/relay-server"` | Remote server path, as installed by `scripts/install-server.sh` |
| `relay-server-local-path` | `"relay-server"` | Server binary path for the `local` (no-SSH) transport — used for smoke testing, and for *any* caller that connects via authority `"local"` (e.g. `relay-exec-raw`/`relay-exec-text` run against the local machine). The default is a bare name, not a path, and won't be found on `$PATH`; leaving it unset makes every `local`-authority call fail silently. Point it at your build, e.g. `server/target/release/relay-server`. |
| `relay-request-timeout` | `30.0` | Seconds to wait for a synchronous server reply before erroring |
| `relay-max-frame-bytes` | 32 MiB | Largest protocol frame accepted from a server, guarding against a malformed/incompatible peer |
| `relay-content-prefetch` | `nil` | Enable opt-in content prefetch (see above) |
| `relay-prefetch-config-file` | `"~/.emacs.d/relay-prefetch.el"` | Where prefetch profiles are persisted |

See the [SSH configuration](#4-ssh-configuration) table above for the
connection-related variables.

## Benchmarks

Measured against real TRAMP (`ssh` method), same remote host, 3 trials each. Cold =
fresh Emacs process, no session cache on either side; warm = second access within
the same session.

| Operation | relay | TRAMP | Speedup |
|---|---|---|---|
| Cold directory listing, 200 files | 0.58s | 2.09s | ~3.6x |
| Cold directory listing, 3000 files | 0.78s | 2.14s | ~2.7x |
| Warm (repeat) directory listing | 0.0007s | 0.0003s | parity — both effectively instant |
| Cold file open | 0.82s | 3.01s | ~3.7x |
| Save | 0.32s | 1.09s | ~3.4x |

The gap is specifically in the **cold/first-touch** case, not a blanket "faster at
everything" claim: TRAMP's own session-level caching makes warm access on both
sides effectively instant, matching this project's own framing of TRAMP's actual
weakness — the synchronous, per-operation blocking round trip on first touch.

## Layout

```
README.md                    This file and installation notes
ARCHITECTURE.md              Design, protocol, and module boundaries
docs/TESTING.md              Local and controlled remote verification
lisp/relay.el                Public loader
lisp/relay-core.el           Framing, transport, connections, name parsing
lisp/relay-prefetch*.el      Listing/content prefetch and Dired UI
lisp/relay-completion.el     Minibuffer authority completion
lisp/relay-file-handler.el   File-name-handler operations and registration
lisp/relay-conflict.el       Revision BASE/LOCAL/REMOTE saves and Ediff UI
server/src/revisions/        Revision reads and atomic conditional writes (see its own README.md)
```

## Prior art

VS Code Remote-SSH (architecture spine), Neovim (headless core + UI protocol),
mosh (local echo + idempotent state-sync), Unison / git partial-clone / VFS-for-Git
(lazy remote filesystems), TRAMP (authority-carrying magic file names), and
[emacs-tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc) (closest
prior art by far — a Rust RPC server replacing TRAMP's shell-command parsing,
built as an actual TRAMP method rather than a sibling handler, and
considerably more feature-complete today: `process-file`/`start-file-process`,
magit/VC integration, PTY support, multi-hop SSH. No public evidence of
revision-safe conditional writes, which appears to be relay's clearest point
of difference).

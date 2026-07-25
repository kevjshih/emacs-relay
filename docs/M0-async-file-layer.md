# Milestone 0 — Async `/relay:` file layer  (the "async TRAMP replacement")

The first shippable slice. A drop-in-ish way to open, browse, edit, and save remote
files via `/relay:ssh+HOST:/path` with **SSH-speed browsing** and **no UI
freezes** — and nothing else yet. This exists to de-risk the one hard unknown
(reconciling Emacs's synchronous file API with async/batched remote I/O) before any
of the bigger subsystems are built on top.

## Goal

Browse / open / edit / save remote files with:
- browsing as fast as an interactive SSH shell (and *faster* on repeat visits),
- newly created remote files visible ≤ SSH speed (§8 freshness),
- Emacs never blocking/freezing on remote ops.

## Non-goals (explicitly deferred)

- Remote command execution (`process-file`) → M1
- Local text model / echo → M2
- Semantic LSP → M3
- Session manifest / persistence / roam → M4
- Local Rust sidecar, fuzzy "open anything" index, offline cache, QUIC → later
- **File-read latency optimization** — deprioritized (§0); a simple read path is fine.

## Architecture

```
  Local Emacs                              Remote host
  ┌─────────────────────────────┐   ssh   ┌──────────────────────────────┐
  │ /relay: handler  (Elisp)  │ <=====> │ relay-server  (Rust binary) │
  │  + directory-listing cache  │  pipe   │  - native readdir + stat     │
  │  + async completion / dired │ (framed │  - read / write              │
  │  (make-process + filter)    │  msgs)  │  - inotify/kqueue watches    │
  └─────────────────────────────┘         │  - streams events            │
                                          └──────────────────────────────┘
```

- **Transport:** one persistent `ssh HOST relay-server` subprocess **per host**;
  requests multiplexed by `id` over stdin/stdout. Reuses SSH's already-fast
  persistent connection (ControlMaster optional). **No shell-command-per-op** — that
  is the single biggest thing that makes TRAMP slow.
- **Local driver:** **pure Elisp for M0** — `make-process` + a process filter that
  parses framed replies; the directory cache is a hash table. (A local Rust sidecar
  is deferred until profiling demands it — fewer moving parts to ship now.)
- **Remote server:** a small **Rust** binary, installed once with
  `scripts/install-server.sh HOST` at `~/.cache/relay/relay-server`. Native
  `readdir`+`stat` is what gives the `ls -la`-in-one-round-trip speed.

## Wire protocol

Length-prefixed framed messages (4-byte LE length + payload). Payload encoding:
JSON is fine for M0 (switch to MessagePack later if it matters). Every request has an
`id`; the reply echoes it; events use `id = 0`.

**Requests (client → server):**

| msg | fields | reply |
|---|---|---|
| `hello` | `version` | `{server_version, os, arch}` |
| `readdir` | `path` | zero or more `{more: true, entries: [...]}` chunks, then `{entries: [...], self_attrs}` — **names + full stat, streamed** |
| `stat` | `path` | `{attrs \| null}` |
| `resolve` | `path` | `{realpath, attrs}` — symlink-resolve + attributes, for cold open |
| `read` | `path` | `{bytes_b64}` (base64; chunked for large files) |
| `write` | `path, bytes_b64` | `{ok}` |
| `watch` / `unwatch` | `path` | `{ok}` |

> **Byte payloads are base64** (`read`/`write`) since JSON can't carry raw bytes.
> Coding-system / EOL conversion is **punted in M0** (treat as raw bytes; UTF-8 for
> text on open). **Head-of-line blocking:** a single stdin/stdout pipe means a large
> `read` streaming back can stall `readdir`/`stat` behind it — which would jank the
> #1-priority browsing. The server therefore **chunks `read` and prioritizes metadata
> ops (readdir/stat/resolve) ahead of content** in its writer queue (or, later, a
> separate metadata channel).

**Events (server → client, `id = 0`):**

| msg | fields | client action |
|---|---|---|
| `event` | `dir, name, kind: created\|deleted\|modified\|renamed` | patch cached listing, notify `file-notify` |
| `overflow` | `dir` | invalidate + re-`readdir` that dir |

## The crux: reconciling the synchronous file API

`file-name-handler-alist` ops are **synchronous by contract** — `file-exists-p`,
`directory-files`, `insert-directory` must return a value *now*. TRAMP satisfies
this by blocking on the network per op; we don't. Strategy:

1. **Answer from cache synchronously (0 network) whenever possible.** One `readdir`
   populates the cache with a whole directory's names **and** attributes, so
   subsequent `file-exists-p` / `file-attributes` / completion for entries in that
   directory are **cache hits → instant**. This is the trick that maps Emacs's
   fine-grained file API onto coarse batched fetches — exactly what TRAMP fails to do.
2. **Cold directory miss → one batched `readdir`, block for a single RTT.**
   SSH-speed and acceptable; prefetching child dirs on entry makes misses rare.
3. **Latency-sensitive interactive surfaces go async *above* the handler:**
   - **find-file completion:** an async completion table — return cached candidates
     immediately, kick off `readdir` if cold, and update candidates from the process
     filter as the reply arrives. The minibuffer never blocks.
   - **dired:** render from cache immediately (a "loading" line on cold miss),
     populate/refresh async, apply `event`s live.
4. **Never block on:** watches, refreshes, prefetch, background revalidation.

Net: the *only* synchronous network wait is a cold `readdir` (one batched RTT);
everything else is cache-instant or async.

### The real hard part: reentrant blocking  (the unknown this spike exists to kill)

The cold-miss RTT is **not** the hard part. Reentrancy is. A synchronous handler op
waits for its reply by looping on `accept-process-output` until the matching response
`id` arrives — and **`accept-process-output` re-enters the Emacs event loop.** While
you are blocked waiting for reply `id=7`, timers fire, other process filters run, and
**nested `file-name-handler` calls can arrive mid-block** — a redisplay hook, a `vc`
hook, or an autosave timer may `stat` another `/relay:` path *while you are inside
the wait*. This reentrancy is precisely where `jsonrpc.el` (eglot) and TRAMP
concentrate their most scar-tissued code.

Requirements the spike must satisfy (and actually prototype):

- **Id-matched request/response.** Monotonic request id; the process filter
  demultiplexes replies into a table keyed by id; the blocking op loops
  `(accept-process-output proc TIMEOUT)` until *its* id resolves (or times out),
  buffering unrelated frames. **Never assume replies arrive in request order.**
- **Reentrancy-safe.** A nested request issued while another is blocked gets its own
  id and resolves independently — no shared mutable parser state a nested call can
  corrupt, no deadlock if the nested reply arrives before the outer one's.
- **Atomic cache mutation.** Replies/events patching the cache may run inside a nested
  `accept-process-output`; cache writes must be atomic w.r.t. a read in the outer
  frame (build the new listing, then swap the hash entry — don't mutate in place).
- **Read `jsonrpc.el`'s request loop before writing your own.** It already solved
  id-matching + reentrancy + timeouts for eglot; mirror it, don't rediscover it.

**Spike acceptance:** demonstrate (a) an id-matched sync request/response over
`accept-process-output`, and (b) a *nested* `/relay:` request arriving mid-block
(e.g. a timer stat-ing another path) completing with **no deadlock and no cache
corruption**. Until this is shown, M0 is not de-risked — everything else is
comparatively routine.

### Cold `find-file` cascades (open is not one stat)

Opening a specific path triggers a *cascade* of blocking ops, not a single stat:
`file-truename` resolves symlinks **component by component** (a stat per path
segment), plus lock-file checks, `file-attributes`, and backup/vc hooks. Cold, that
is N sequential round-trips. Mitigations:

- Add a **batched `resolve`** op: resolve the full path's symlinks + return its attrs
  **and** the parent directory listing in one round-trip, so open doesn't cascade.
- Prewarm the parent `readdir` on the completion path so by the time you open, the
  parent (and thus most stats) are already cached.
- **`file-truename` is a remote op**, not a local/pure path op — for `/relay:`
  paths it needs remote symlink resolution (see handler table).

## Handler op mapping

| Emacs op | M0 handling |
|---|---|
| path ops (`expand-file-name`, `file-name-directory`, `file-name-as-directory`, …) | local, pure |
| `file-truename` | **server** (`resolve`) — remote symlink resolution, *not* local/pure |
| `directory-files`, `directory-files-and-attributes`, `file-name-all-completions`, `file-name-completion` | from cached `readdir`; cold → one batched `readdir` |
| `insert-directory` (dired) | from cache; async populate + live events |
| `file-exists-p`, `file-attributes`, `file-readable-p`, `file-directory-p` | from cached parent `readdir` |
| `insert-file-contents` (open) | server `read` (latency deprioritized) |
| `write-region` (save), `delete-file`, `rename-file` | server `write` / ops |
| `file-notify-add-watch` / `-rm-watch` | server `watch` / `unwatch`; events → cache patch + `file-notify` callbacks |
| `process-file`, `start-file-process`, `shell-command` | **unsupported in M0** — signal a clear error; deferred to M1 |

## Freshness (implements §8)

- On every `readdir`, auto-`watch` that directory. `event`s patch the cache, so a
  process-created file **appears within ~1 RTT with no manual re-list** (faster than
  SSH).
- `overflow` → invalidate + re-`readdir` (never silently miss files).
- Manual refresh (dired `g`) → forced `readdir` = ground truth at SSH speed.

## Bootstrap

1. Run `scripts/install-server.sh HOST` once. It detects the remote platform,
   builds the matching local target, and installs it at
   `~/.cache/relay/relay-server`.
2. First `/relay:ssh+HOST:` access launches that server and performs the `hello`
   handshake.
3. Reuse that connection for all ops to the host; relaunch on drop.

## Acceptance tests (this is the de-risking bar)

- Browsing a large remote dir: first listing ≈ one SSH `ls` RTT; **repeat visits
  instant**; typing in `find-file` **never blocks**, even on a cold directory.
- `touch` a file in that dir from a separate SSH session → it **appears within ~1
  RTT with no manual refresh**.
- Write 10k files (watch overflow) → listing **re-enumerates, no missing files**.
- Open + edit + save a file round-trips correctly.
- Emacs **never freezes** during any of the above.

## What this unlocks

- **M1** — `process-file` / `start-file-process` over the server → magit, vc, grep,
  compilation via local-exec/remote-I/O (§3 option b).
- **M2** — local text model + echo (decouples editing from read/write latency) +
  tree-sitter local syntactic tier.
- **M3** — semantic LSP (client-local per §9) + degradation policy.

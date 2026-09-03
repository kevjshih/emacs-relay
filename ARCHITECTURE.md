# Relay — Design Plan

*A VS Code Remote–style architecture for Emacs: a thin local GUI frontend
attached to a headless remote daemon, with instant local editing, remote
workspace compute, seamless TRAMP-like browsing, and graceful offline
degradation.*

Project name: **Relay**. Path prefix: **`/relay:`**.

---

## 0. Goal

Run a **thin local GUI Emacs (the UI)** attached to a **headless remote Emacs
daemon (the server)**. Typing is instant (local text model + echo); all heavy
workspace compute (LSP, search, git, build) runs on the remote, co-located with
the code; the session persists server-side so you can detach, reconnect, and
roam; and the whole thing browses the remote filesystem as seamlessly as TRAMP —
but without TRAMP's per-operation latency.

We adopt **VS Code Remote's architecture as the spine**, and park our two more
ambitious ideas (offline-first caching, loss-resilient transport) as a clearly
scoped later phase.

> **Explicit priority ordering:** **browsing/enumeration speed is the top
> requirement** — it must match an interactive SSH shell (and newly created remote
> files must surface as fast as they would via `ls`/`fd` over SSH). **File-read
> latency is explicitly deprioritized** — slower reads are acceptable. Engineering
> effort concentrates on the enumeration path (§8); the content-fetch path (§7) can
> stay simple.

---

## 1. Guiding principles (the invariants)

1. **Local text model + instant echo.** Typing edits a local buffer; nothing
   round-trips. (VS Code's actual latency fix — we converged on it independently.)
2. **Async remote semantics.** Completion/diagnostics/search come from the remote
   asynchronously. Latency degrades *freshness, not smoothness*.
3. **No synchronous network wait on the interactive path.** Nothing on the input
   or redisplay path may block on the network. (The #1 fix vs. today's
   `lsp-over-tramp`, which freezes Emacs on sync calls.)
4. **Relocate *data-heavy processing* to where its data is native — but only when
   needed.** The server (language servers, git) runs remote so its file/dep access
   is local-to-the-remote. But note Emacs's magic-file-name handler already gives
   *local execution with remote I/O* for free — so "runs remote" should mean
   "executes remote" only when chattiness (N round-trips) actually demands it, not
   as a default. See §3's (a)/(b) distinction.
5. **One list drives everything.** The set of open files is simultaneously the
   layout manifest, the lazy-fetch/cache spec, and the sync scope.
6. **Structure eager, content lazy.** Browse the whole tree (cheap, daemon-served
   listings); materialize file content only on open.
7. **Graceful degradation is a first-class contract**, not a bolt-on: passive
   features go stale, active commands fail fast, local/syntactic keeps working,
   everything auto-resumes on reconnect.

---

## 2. Architecture overview

```
  LOCAL (laptop)                         REMOTE (dev host)
  ┌────────────────────────┐            ┌─────────────────────────────┐
  │ GUI Emacs  (the "UI")  │            │ Headless Emacs (the "server")│
  │  - rendering, keymaps  │            │  - eglot/LSP client          │
  │  - window/frame layout │            │  - project.el, magit, vc     │
  │  - completion UI       │            │  - compilation               │
  │  - LOCAL text model    │            │  - authoritative buffer mirror│
  │  - tree-sitter (syntax)│            └─────────────┬───────────────┘
  │  - /relay: handler   │                          │ (local, native paths)
  └───────────┬────────────┘                          │
              │ Elisp <-> sidecar (async socket)      │
  ┌───────────┴────────────┐            ┌─────────────┴───────────────┐
  │ Rust client engine     │  <=======> │ Rust server engine          │
  │  - local cache / VFS   │  sync/QUIC │  - FS watch (inotify)        │
  │  - listing cache       │  transport │  - tree enum + fuzzy index   │
  │  - edit-delta compute  │            │  - content store, merge      │
  │  - transport client    │            │  - LSP result fan-out        │
  └────────────────────────┘            └─────────────────────────────┘
                                                        │
                                              ┌─────────┴─────────┐
                                              │ Language servers  │
                                              │ (rust-analyzer,…) │
                                              └───────────────────┘
```

> **Diagram note:** the remote box shows the *client-remote* LSP option (eglot +
> buffer mirror on the remote). The plan **leans toward client-local** (§9), in
> which eglot and its rendering move to the local frontend, the buffer mirror
> disappears, and the remote may shrink to *language servers + git + Rust engine +
> a thin server* rather than a full headless Emacs.

- **File truth = remote disk.** The local model is the fast editable view; **save**
  writes it back to the remote.
- **Whole-tree operations run remote** (search, xref, repo git status) and stream
  results — the frontend never holds the full tree.

---

## 3. Execution-kind boundary  *(VS Code's best idea — but Emacs needs a sharper version)*

Every feature is classified for **where it runs** — but "runs remote" has **two
distinct meanings that must not be conflated**:

- **(a) Executes remote** — the package's Elisp runs *in the remote Emacs*.
- **(b) Local execution, remote I/O** — the package runs *locally* but its file
  access and subprocesses target the remote via the `/relay:` handler
  (`process-file`, `directory-files`, …). This is TRAMP's model, made fast.

**Why the distinction is load-bearing:** VS Code's `ui`/`workspace` split works
because extensions emit *data* that a separate core *renders*. **Emacs packages
paint in-process** (overlays, text properties, dedicated buffers). So option (a)
for an interactive package (magit, dired, eglot's own rendering) means its
*painting* happens in the remote Emacs — which drops us right back onto the
display-decoupling wall this whole design exists to avoid. Filing a package under
"workspace/remote" via (a) does **not** make it work remotely; it inherits the
core difficulty.

**Default to (b), reserve (a) for genuine chattiness.** Emacs's handler already
gives remote I/O without relocating execution, and (b) keeps all rendering local.
Use (a) only where a package fires *many* small ops (e.g. magit-status = dozens of
git calls + stats on a big repo) and paying N network round-trips would hurt —
and accept that such packages then need a remote-server / result-forwarding
treatment, not naive in-place remote execution.

| Clearly `ui` (local) | Clearly (b) local-exec / remote-I/O | Candidate (a) remote-exec (only if chatty) |
|---|---|---|
| rendering, keymaps, themes | file I/O, save/open | magit-status on large repos |
| completion **UI** | `project.el`, enumeration/browsing | (evaluate case-by-case) |
| minibuffer, which-key | LSP **client** (eglot) — see §9 | |
| **tree-sitter** (local syntax) | vc, compilation dispatch | |
| local text model + echo | grep/xref (remote subprocess) | |

The **remote server** always runs the *language servers and git* natively
(required). Whether it also runs a *full headless Emacs* depends on how many
packages land in column (a) — possibly it needs only language servers + git +
the Rust engine + a thin server. This classification is the core *new* thing we
build; a monolithic Emacs has never had it.

---

## 4. Path & identity model

Follow VS Code: **don't blend local and remote paths — disambiguate them with an
authority, and dispatch filesystem ops on it.**

- Represent remote resources as an Emacs magic file name:
  **`/relay:TYPE+HOST:/absolute/remote/path`**
  e.g. `/relay:ssh+myhost:/home/alice/foo.ts`
  (structured `TYPE+HOST` authority, mirroring VS Code's `ssh-remote+host` — room
  for `container+id`, `codespaces+name` later.)
- Implement it as our **own `file-name-handler-alist` entry** (a *sibling* to
  TRAMP, not a TRAMP method — our transport is a persistent daemon, not a login
  shell). Register **ahead of TRAMP** so its greedy autoload regexp never claims
  our names.
- On the **remote daemon**, files are **bare native paths** (`/home/alice/...`) —
  no prefix, no per-op SSH — because workspace code *is* on the remote. Only the
  frontend carries the `/relay:` identity; the sync layer strips it at the
  boundary.
- **TRAMP is demoted to bootstrap only** — copy the daemon over, start it,
  health-check (like VS Code using SSH to install its server). Steady-state file
  ops go through *our* handler. The two live in separate namespaces by
  construction → no conflict.

**Footgun to design around** (our version of VS Code's `.fsPath`-loses-authority):
`buffer-file-name` / `default-directory` must have **one canonical mapping and a
single rule** per side, or path-comparison code breaks.

---

## 5. Latency model

- **Local text model + instant echo** — typing never round-trips.
- **Semantic features async-remote** — a beat late, never blocking.
- **Hard rule:** no synchronous network wait on the input/redisplay path. Enforced
  *architecturally* by putting transport/cache in a Rust **sidecar process**
  (Emacs talks to it over an async socket) rather than in-process.

---

## 7. File & content model  (lazy git-style, VFS-for-Git shape)

> **Read latency is explicitly deprioritized** (see §0). Content fetch can be a
> simple, even slow, path in Phase 1 — no aggressive read optimization needed. All
> the speed budget goes to §8 browsing. (Enumeration is *structure*, not content, so
> deprioritizing reads does not slow browsing.)

- **Lazy content, eager structure.** Enumerate the whole tree (cheap, cached);
  materialize file *content* only on open. Same split as git partial-clone /
  sparse-checkout / git-annex / VFS-for-Git / Scalar.
- **Whole-tree ops run remote** (grep, xref, "open anything", repo git status) —
  the frontend lacks the full tree.
- **Each cached file carries its base revision** (content-addressed) — required for
  a safe three-way merge in the offline phase; without it, reconnect is
  last-write-wins = silent data loss.

### Connected revision-safe saves (implemented)

The connected file layer now applies that base-revision rule to every ordinary
visited-file save.  Protocol v1 requires the server capability `revisions-v1`;
each successful read and conditional write carries a schema-1 token containing
file identity, metadata, and a SHA-256 hash.  A missing path has an explicit
missing BASE.  Under one mutation lock, the server verifies the expected state,
writes and flushes a same-directory temporary file, verifies again, and publishes
atomically.  Machine-readable conflicts distinguish changed, deleted, appeared,
and type-changed paths.

The client keeps BASE (last successful open/reload/save), LOCAL (encoded buffer),
and a freshly fetched REMOTE.  Byte comparison handles edits undone back to BASE
and convergent LOCAL/REMOTE edits correctly.  Divergence offers whole-file
choices plus three-way Ediff over independent snapshots; all write-producing
choices remain conditional on the fetched REMOTE revision.  Auto-Revert controls
when clean remote changes become visible, but save correctness does not depend on
notifications.  An unconfirmed transport write is read back and classified; it
is never retried blindly.

Interactive `C-x C-s` is implemented by `relay-save.el` as a callback state
machine. It captures the visited identity, BASE, encoded LOCAL, and a generation,
then returns before connecting or waiting for the write reply. The standard
modified bit remains authoritative during the flight. A successful reply advances
BASE and clears the bit only when both the live identity and bytes still match;
otherwise it records the confirmed snapshot as BASE but leaves newer edits dirty.
Repeated saves retain only the latest distinct requested snapshot, dispatched
against the prior write's returned revision. Any conflict, definite failure, or
ambiguous result cancels that queue. Direct programmatic saves keep the synchronous
file-handler path.

This first implementation accepts only regular UTF-8 files up to 16 MiB.
Binary content, final symlinks, hard links, directories, FIFOs, and other
non-regular targets are rejected rather than replaced.

---

## 8. Browsing / enumeration  — **TOP PRIORITY**

**Goal: browsing as fast as an interactive SSH shell, and faster on repeat visits.**
This is a headline requirement, ranked above file-read latency (see §7).

### Diagnosis: why interactive `ssh` is fast and TRAMP is slow

- **`ssh` + `ls -la` is fast** because it is *one native command* returning a whole
  directory's names **and** attributes in **one round-trip**, streamed over an
  already-open connection, blocking nothing.
- **TRAMP is slow** — and *not* from SSH re-handshaking (it reuses a persistent
  connection) — but from three things:
  1. it **blocks Emacs synchronously** on every remote op (so even fast ops feel
     laggy and pile up);
  2. **fine-grained ops become separate round-trips** — completion and
     `file-attributes` issue per-file remote work instead of reusing one batched
     directory read;
  3. **shell-command + prompt-parsing overhead** per operation.

### Design: replicate the SSH model, then beat it with cache + prefetch

1. **Batch at directory granularity.** The remote server does one native
   `readdir` + `stat` for the whole directory (the `ls -la` equivalent) and streams
   back *names + full attributes together* — one round-trip per directory, never
   per file.
2. **Serve all fine-grained ops from that batched result.** `file-exists-p`,
   `file-attributes`, `file-name-all-completions` are answered from the cached
   directory listing → **zero round-trips** after the first fetch. This is the trick
   that maps Emacs's fine-grained file API onto coarse batched fetches (exactly what
   TRAMP fails to do).
3. **Never block.** All enumeration is async over the persistent sidecar channel;
   the interactive path renders from cache immediately and fills in async. Matches
   SSH's non-blocking feel.
4. **Cache + reactive freshness.** Cache directory listings locally; the remote
   engine watches the FS (`inotify`/`kqueue`) and **pushes invalidations**, so repeat
   visits are 0-RTT and stay correct without polling.
5. **Prefetch to beat SSH.** On entering a directory, speculatively fetch child
   subdirectories and warm the completion path, so navigating *inward* feels
   instant — faster than cold interactive `ls`.
6. **Whole-tree "open anything"** (`project-find-file`) is a single streamed native
   command on the remote (`fd` / `git ls-files`, indexed by the Rust engine) — the
   same reason `fzf`-over-ssh feels instant.

### Freshness: a newly created remote file appears at least as fast as `ls` over SSH

Requirement: if any remote process creates a file, it must be findable as quickly as
via an interactive SSH session — the cache must **never be staler than a fresh `ls`**.

- **Watch every cached directory.** When a listing is cached, register an FS watch
  on that directory (`inotify`/`kqueue`/`fanotify`). A create/rename/delete fires an
  event the engine pushes to the client, which patches the cached listing — so the
  file **appears automatically within ~one push RTT**, without you re-running `ls`.
  This is *faster* than SSH (no manual re-list needed).
- **Uncached directories cost nothing extra.** First visit is a fresh native
  `readdir` (cache miss = SSH-equivalent), so staleness never exceeds SSH anywhere.
- **The fuzzy index tracks the same event stream** — new files become findable in
  `project-find-file` incrementally as created (within push latency), not on a
  periodic rescan.
- **Always-available ground-truth revalidation.** A manual refresh (dired `g`, or
  "re-list now" on any path) forces a fresh native `readdir`/`fd` — one streamed
  command, definitionally SSH-speed — so you can *always* get live truth at SSH cost.
- **Robustness:** on watch-queue overflow (`IN_Q_OVERFLOW`, e.g. a build writing
  thousands of files) or a dropped watch, **invalidate and re-enumerate** the
  affected directories rather than silently miss events. A short revalidate-on-focus
  TTL backstops any missed watch.

**Net guarantee: never staler than SSH, usually fresher** — files surface without a
manual re-list, with a native-revalidation escape hatch that is SSH-speed by
definition.

### Interface

- Implement the directory/attribute ops in the `/relay:` handler
  (`directory-files`, `file-name-all-completions`, `insert-directory`,
  `file-attributes`) so `find-file` completion, `dired`, and `project-find-file`
  just work — but back them with the batched-cache engine above, **not** per-op
  remote calls.
- Once inside a workspace, `default-directory` stays `/relay:…` so relative
  navigation feels local; prefix + modeline indicator is the only marker
  (mirroring VS Code's "SSH: myhost" status bar).

---

## 9. Language engine  (syntactic local / semantic remote)

- **Syntactic tier → LOCAL.** tree-sitter (built into Emacs 29+) needs only buffer
  text: highlighting, indentation, structural nav/folding stay instant and
  offline-capable. The editor never feels dead.
- **Semantic tier → REMOTE, but only the *server* is forced remote.** The language
  **server** (rust-analyzer, pyright, gopls, …) must run remote — it needs the whole
  project + toolchain + deps, and its internal file reads are then local-to-the-remote
  regardless of anything else. That fast file access comes from the *server* being
  remote; it does **not** require the *client* to be remote.
- **LSP client placement is the key open decision (see risk #1):**
  - **Client LOCAL (leaning this way, per principle #2):** eglot runs in the frontend,
    reads the *local* buffer directly, renders diagnostics/completions *locally* (no
    forwarding bridge), and ships `didChange` (async notifications) + a few
    request-response calls (completion/hover) over the fast sidecar channel to the
    remote server. Cost: one async round-trip per *interactive request* — which
    principle #2 explicitly accepts (freshness, not smoothness). Wins: **no remote
    buffer mirror, no per-result-type extraction bridge, possibly no full remote
    Emacs.** The three things that made `lsp-over-tramp` slow are already gone — the
    persistent async channel kills per-op SSH + UI-freezing, and the local text model
    means eglot reads a local buffer, not a TRAMP file.
  - **Client REMOTE (the heavier option):** eglot runs in the remote Emacs against a
    buffer *mirror* fed by local edits; LSP JSON-RPC is local/fast, but results must
    be extracted and forwarded to the frontend per type, and the mirror is what
    creates risk #3. Justified only if the client↔server chatter proves too costly
    over the channel — unlikely, since `didChange` is fire-and-forget.
- **Consequences accepted:** "do it in Rust" does *not* extend to language
  intelligence (those are external language servers); and the remote must be a
  **provisioned dev environment**, not a dumb file host (devcontainer/provisioning
  setup is a separate, out-of-scope concern here).

---

## 10. Degradation & fallback  (one policy for the whole workspace tier)

- **Connection state is first-class:** heartbeat on the sync channel; three states
  **connected / reconnecting / offline**; modeline indicator. When offline,
  semantic requests are **not sent** (short-circuit locally) rather than
  sent-and-timed-out.
- **Passive feedback degrades silently:**
  - Completion → fall back to local sources (tree-sitter/dabbrev).
  - Diagnostics → **freeze last-known set and mark stale**; never *clear* (clearing
    falsely implies "clean").
  - Hover/signature → quietly unavailable.
- **Active commands fail fast with a reason:** rename, code actions, find-refs,
  format-on-save → "unavailable offline." Never fake, never dangerously queue
  (a queued cross-file rename is unsafe — the code moved).
- **Syntactic floor stays up** (tree-sitter local) — editor stays alive.
- **Reconnect = re-sync, not just re-attach:** replay buffered edits / re-`didOpen`
  so the server re-indexes current content, then resume + republish. Auto-reconnect
  with backoff; no manual restart.
- **Cleanup:** cancel in-flight requests on drop; coalesce/suppress error spam into
  one status indicator.
- **Unification:** the same state machine serves a 2-second packet-loss blip and a
  2-hour flight, and the same policy covers *all* workspace features (LSP, grep,
  magit, compilation), not just LSP.

---

## 11. Implementation stack

**Model:** Rust as the *engine below*, thin Elisp *shims* on the interactive path,
two Emacsen for editor semantics. You cannot (and should not) rewrite
buffers/redisplay in Rust — that's Emacs's C core, reachable only from Elisp.

Two ways to embed Rust, used deliberately:
- **Dynamic module** (`emacs-module.h`, Emacs 25+; the `emacs` crate) — for
  **synchronous, CPU-bound, returns-fast** work (fuzzy match, string diff, hash).
  *Caveat:* `emacs_env` is not thread-safe; module code touches Emacs on the main
  thread only.
- **Sidecar process** — for **I/O-heavy / long-running** work (transport, cache, FS
  watch). Emacs talks to it over an async socket → naturally non-blocking. This is
  how the "no sync wait" rule is *enforced*, not just followed.

Rust efficiency wins + candidate crates:
- Tree walk + fuzzy index → `ignore`, **`nucleo`** (Helix's matcher) — "open
  anything" over huge monorepos, which Elisp is slow at.
- Cache / VFS / content-addressing → `blake3`, `notify` (FS events).
- Diff/delta for buffer + file sync → `similar` / a rope.
- Transport (Phase 3) → **QUIC via `quinn`** (UDP-based, multiplexed, encrypted,
  roaming/loss-tolerant — a better modern version of the mosh-style transport).
- Merge (Phase 3) → `gix` / `git2`.

**Feasibility precedent:** Emacs's tree-sitter integration *started as a Rust
dynamic module* (`elisp-tree-sitter`) before landing in core — a heavy Rust module
driving Emacs at scale, in production. Sidecar integration is standard (ripgrep/fd
/language servers).

**Rust is the fast *pipe* between the two Emacsen, not a replacement for either.**

The current connected-file implementation is split so work on one subsystem
does not require parsing or editing a monolith: `lisp/relay.el` is a small
public loader; `relay-core.el` owns framing, transport, and connections;
`relay-prefetch.el`, `relay-content-prefetch.el`, and
`relay-prefetch-ui.el` own cache/prefetch policy; `relay-completion.el` owns
authority completion; `relay-file-handler.el` owns ordinary file operations;
`relay-conflict.el` owns revision state and synchronous conditional-write
compatibility, and `relay-save.el` owns asynchronous interactive state and UI;
the two share request preparation. Recovery buffers and Ediff live at their
boundary. The server's revision implementation is similarly isolated in
`server/src/revisions/`.

---

## 12. Reuse map (Emacs primitives to build on)

- `emacs --fg-daemon` — the server process.
- **TRAMP / SSH** — bootstrap (deploy + start daemon) and initial FS reach.
- `desktop.el` + `frameset.el` + `window-state-get` — manifest serialization
  (strip sizes).
- `eglot` / `lsp-mode` remote clients — remote LSP.
- Built-in **tree-sitter** — local syntactic tier.
- `filenotify` — FS watching hook (native side in Rust).
- `smerge-mode` / `ediff` / the "changed-on-disk" flow — conflict UX (Phase 3).

---

## 13. Phased roadmap

**Phase 1 — MVP, built in milestones (connected-only, like Remote-SSH)**

- **M0 — async `/relay:` file layer** *(start here — see
  [`docs/M0-async-file-layer.md`](./docs/M0-async-file-layer.md))*. An **async TRAMP
  replacement**: browse / open / edit / save remote files over a persistent
  SSH-launched Rust server, with **SSH-speed browsing**, SSH-speed freshness for new
  files, and **no UI freezes**. Pure-Elisp local driver; no local model / LSP /
  sessions yet. This slice de-risks the synchronous-file-API-vs-async-I/O problem.
- **M1 — remote command execution** (`process-file` / `start-file-process` over the
  server) → unlocks magit, vc, grep, compilation via local-exec/remote-I/O (§3 (b)).
- **M2 — local text model + echo** (decouple editing from read/write latency) +
  **tree-sitter** local syntactic tier.
- **M3 — semantic LSP** (client-local, per §9) over the channel; basic degradation
  policy (connection states, fail-fast/stale).
- Execution-kind classification (§3) applied incrementally as packages are onboarded.

**Phase 3 — Resilience + offline**
- Offline-first lazy cache + git-style three-way merge (base revision per file).
- Loss-resilient QUIC transport (idempotent state-sync).
- ~~Full conflict UX via smerge/ediff~~ — **done**, ahead of the rest of this
  phase: connected-only BASE/LOCAL/REMOTE tracking with a whole-file conflict
  menu and three-way Ediff merge shipped as part of M0's revision-safe saves
  (see §7's "Connected revision-safe saves" note and `README.md`'s
  "Conflict-safe remote saves" section). What's still unbuilt is the other
  two bullets above — a persistent offline-usable cache and a
  resumable/loss-resilient transport — which is what "conflict UX" actually
  needed the *offline* half of this phase for: reconciling a whole
  disconnected editing session, not just one save.

---

## 14. Open risks / hard problems (ranked)

1. **Emacs packages paint in-process — they are NOT logic/render-decoupled like VS
   Code extensions.** So "run this package remotely" (option (a) in §3) inherits the
   display-decoupling wall; it doesn't sidestep it. Every interactive workspace
   package must be triaged: local-exec/remote-I/O (b, default) vs. remote-exec with
   a bespoke result-forwarding bridge (a, only if chatty). Getting this wrong
   silently reintroduces the exact problem the design exists to solve. The LSP
   client placement (§9) is the first and most important instance.
2. **Buffer identity canonicalization** (`buffer-file-name` / `default-directory`
   consistency across frontend and daemon) — our `.fsPath` footgun; a major source
   of real bugs.
3. **Sync protocol correctness** — edit-delta ordering, cancellation, re-sync on
   reconnect without dropped/duplicated edits.
4. **Same-buffer concurrent mutation** (multi-client, or server-side format-on-save
   / LSP `willSave` edits) — the one case needing true predict-and-reconcile /
   CRDT. Rare for single-user/single-client; must not corrupt when it happens. Note:
   this risk largely *disappears* under the client-LOCAL choice in §9 (no mirror).
5. **Offline merge & tree ops** (Phase 3) — creates/renames/deletes must reconcile
   directory structure, not just content; lean on `gix`, don't hand-roll rsync.
6. **Per-platform native binary deployment** — the daemon bootstrap must ship the
   right module/sidecar to the remote (like VS Code Server's native bits).
7. **FS-watch scale & overflow** (freshness, §8) — `inotify` is per-directory with a
   per-user watch limit; recursively watching a huge monorepo can exhaust it, and
   heavy churn can overflow the event queue. Mitigations: watch only *cached* (i.e.
   actually-browsed) directories, invalidate-and-re-enumerate on overflow, and keep
   the native "re-list/re-scan now" path (SSH-equivalent) as the always-correct
   fallback for anything the incremental index misses.

---

## 15. Prior-art references

- **VS Code Remote-SSH** — architecture spine (local UI + local model, remote
  server, extension-kind `ui`/`workspace`, server persistence).
- **Neovim** — proof an editor can split into headless core + UI protocol
  (msgpack-RPC); works because its render model stayed grid-shaped.
- **mosh** — local speculative echo + idempotent UDP state-sync (latency/loss).
- **Unison / git (partial clone, sparse-checkout, git-annex) / VFS-for-Git,
  Scalar / Google CitC** — lazy, only-touched-files remote filesystems + sync.
- **TRAMP** — magic file names as authority-carrying URIs; the handler-op interface
  we implement.
- **[emacs-tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc)** — closest
  prior art by far, found after most of M0 was already built: a Rust RPC server
  (MessagePack-RPC, evolved from an earlier JSON-RPC version specifically to drop
  base64's ~33% overhead on binary file content — a choice relay hasn't made yet)
  replacing TRAMP's shell-command parsing, distributed as an actual TRAMP method
  rather than a sibling handler. Considerably more feature-complete today:
  `process-file`/`start-file-process`/`make-process` (unlocking eglot, magit, VC,
  PTY support for vterm/eat), multi-hop SSH, batch/pipelined requests. Checked its
  public docs and RPC method table specifically for anything resembling
  optimistic-concurrency conditional writes; found none — relay's BASE/LOCAL/REMOTE
  revision tracking and conditional writes (§7) appear to be its clearest point of
  difference, though this is based on documentation, not their source.

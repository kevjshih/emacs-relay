/// Filesystem operations: read, write, stat, readdir, resolve, etc.
///
/// These run in a bounded worker pool so slow content ops never head-of-line-block metadata ops.

use crate::framing::{self, expand_home, finish_revision, send};
use crate::revisions;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, SyncSender};
use std::time::{Duration, Instant};

/// Chunk size for streaming `readdir` replies. Not client-configurable for
/// this first cut — a plain constant is enough to fix the actual problem
/// (no giant single blob, no unbounded buffer before the first byte).
const READDIR_CHUNK_SIZE: usize = 2000;

/// Default wall-clock budget for `exec` when the request omits `timeout_ms`.
/// A hung child must not be allowed to occupy a worker thread indefinitely —
/// the pool is shared (8 threads total) with every other FS operation.
const DEFAULT_EXEC_TIMEOUT_MS: u64 = 30_000;

/// Floor applied to the remaining budget when collecting `exec`'s stdout/
/// stderr on the success path (see `exec_command`). `try_wait()` is polled
/// every 20ms, so it can observe the child's exit slightly after
/// `timeout_ms` has technically elapsed, leaving ~0ms of nominal budget to
/// collect output that a concurrent reader thread has, in the ordinary
/// case, already finished reading and is a `recv` away from delivering.
/// Without this floor, `recv_timeout` on an exhausted budget would behave
/// like `try_recv` and could spuriously report a timeout for a command
/// that actually succeeded and whose output was microseconds away. This
/// grace period is intentionally tiny relative to `timeout_ms` and does
/// not change the overall guarantee: total time is still bounded by
/// `timeout_ms` plus this small, fixed collection grace, not by however
/// long a lingering grandchild lives.
const EXEC_COLLECT_GRACE_MS: u64 = 100;

/// FS ops: run on their own thread (see main loop) so slow content ops never
/// head-of-line-block metadata ops.
pub(crate) fn handle_fs(req: &Value, tx: &SyncSender<Vec<u8>>) {
    let id = req.get("id").and_then(Value::as_i64).unwrap_or(0);
    let op = req.get("op").and_then(Value::as_str).unwrap_or("");
    let path = expand_home(req.get("path").and_then(Value::as_str).unwrap_or(""));
    // `readdir` streams its own chunked replies (see `readdir_stream`) rather
    // than producing one `Result<Value, String>` for `finish` to send —
    // pulled out of the uniform match below since every other op here is a
    // single request/single reply.
    if op == "readdir" {
        readdir_stream(&path, tx, id);
        return;
    }
    if op == "read" {
        let result = revisions::read_with_revision(Path::new(&path)).map(|read| {
            json!({
                "bytes_b64": B64.encode(read.bytes),
                "revision": read.revision.to_value(),
            })
        });
        finish_revision(tx, id, result);
        return;
    }
    if op == "write" {
        let append = req.get("append").and_then(Value::as_bool).unwrap_or(false);
        let must_be_new = req
            .get("must_be_new")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        match expected_revision_from_request(req) {
            Ok(Some(expected)) if !append && !must_be_new => {
                let bytes = match req.get("bytes_b64").and_then(Value::as_str) {
                    Some(encoded) => match B64.decode(encoded) {
                        Ok(bytes) => bytes,
                        Err(error) => {
                            framing::finish(tx, id, Err(format!("write decode: {error}")));
                            return;
                        }
                    },
                    None => {
                        framing::finish(tx, id, Err("write: missing bytes_b64".into()));
                        return;
                    }
                };
                let result = revisions::conditional_write(Path::new(&path), &bytes, &expected)
                    .map(|saved| json!({"revision": saved.revision.to_value()}));
                finish_revision(tx, id, result);
                return;
            }
            Ok(_) => {}
            Err(error) => {
                framing::finish(tx, id, Err(error));
                return;
            }
        }
    }
    // Revision writes take this same lock internally.  All other mutations
    // take it here so a legacy operation cannot race their compare-and-swap.
    let _mutation_guard = if matches!(
        op,
        "write" | "mkdir" | "rmdir" | "delete" | "rename" | "copy"
    ) {
        Some(revisions::mutation_guard())
    } else {
        None
    };
    let result: Result<Value, String> = match op {
        "stat" => Ok(json!({ "attrs": stat_value(Path::new(&path)) })),
        "resolve" => resolve(&path),
        // `exec` has no `path` of its own in the sense every other op here
        // does — `path` above (computed from `req.get("path")`, empty when
        // absent) is simply unused by this arm. It spawns an unrelated
        // process, so it deliberately does NOT take `_mutation_guard`
        // (that lock exists to serialize filesystem-mutation ops against
        // the revision-tracking system; orthogonal here).
        "exec" => exec_command(req),
        "write" => {
            let b64 = req.get("bytes_b64").and_then(Value::as_str).unwrap_or("");
            let append = req.get("append").and_then(Value::as_bool).unwrap_or(false);
            let must_be_new = req
                .get("must_be_new")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            write_file(&path, b64, append, must_be_new).map(|_| json!({ "ok": true }))
        }
        // Mutation ops. Emacs distinguishes "file" from "directory" removal and
        // recursive from non-recursive, so we mirror that rather than collapsing
        // them — a non-recursive rmdir on a non-empty dir must fail, not wipe it.
        "mkdir" => {
            let parents = req
                .get("parents")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let r = if parents {
                fs::create_dir_all(&path)
            } else {
                fs::create_dir(&path)
            };
            r.map(|_| json!({})).map_err(|e| format!("mkdir: {e}"))
        }
        "rmdir" => {
            let recursive = req
                .get("recursive")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let r = if recursive {
                fs::remove_dir_all(&path)
            } else {
                fs::remove_dir(&path)
            };
            r.map(|_| json!({})).map_err(|e| format!("rmdir: {e}"))
        }
        "delete" => fs::remove_file(&path)
            .map(|_| json!({}))
            .map_err(|e| format!("delete: {e}")),
        "rename" => {
            let to = expand_home(req.get("to").and_then(Value::as_str).unwrap_or(""));
            let ok_if_exists = req
                .get("ok_if_exists")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            if !ok_if_exists && Path::new(&to).exists() {
                Err(format!("rename: destination exists: {to}"))
            } else {
                fs::rename(&path, &to)
                    .map(|_| json!({}))
                    .map_err(|e| format!("rename: {e}"))
            }
        }
        "copy" => {
            let to = expand_home(req.get("to").and_then(Value::as_str).unwrap_or(""));
            let ok_if_exists = req
                .get("ok_if_exists")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            if !ok_if_exists && Path::new(&to).exists() {
                Err(format!("copy: destination exists: {to}"))
            } else {
                // fs::copy carries permission bits over, which is what
                // `copy-file' with KEEP-TIME/preserve-permissions expects.
                fs::copy(&path, &to)
                    .map(|_| json!({}))
                    .map_err(|e| format!("copy: {e}"))
            }
        }
        other => Err(format!("unknown fs op: {other}")),
    };
    framing::finish(tx, id, result);
}

fn expected_revision_from_request(
    req: &Value,
) -> Result<Option<revisions::ExpectedRevision>, String> {
    if let Some(state) = req.get("expected_state").and_then(Value::as_str) {
        return match state {
            "missing" => Ok(Some(revisions::ExpectedRevision::Missing)),
            "present" => Err("write: expected_state present requires expected_revision".into()),
            _ => Err(format!("write: invalid expected_state: {state}")),
        };
    }
    let Some(value) = req.get("expected_revision") else {
        return Ok(None);
    };
    let revision = revisions::Revision::from_value(value)
        .map_err(|error| format!("write: invalid expected_revision: {error}"))?;
    Ok(Some(revisions::ExpectedRevision::Present(revision)))
}

/// lstat-style attributes (does not follow the final symlink).
fn stat_value(p: &Path) -> Value {
    match fs::symlink_metadata(p) {
        Ok(md) => {
            let ft = md.file_type();
            let kind = if ft.is_dir() {
                "dir"
            } else if ft.is_symlink() {
                "symlink"
            } else {
                "file"
            };
            let target = if ft.is_symlink() {
                fs::read_link(p).ok().map(|t| t.to_string_lossy().to_string())
            } else {
                None
            };
            json!({
                "kind": kind,
                "size": md.size(),
                "mtime": md.mtime(),
                // Sub-second precision: `mtime` alone is integer seconds, so
                // two changes inside the same second are indistinguishable
                // to a caller comparing it (matters for reconnect-listing
                // revalidation, which relies on directory mtime to detect
                // "changed while disconnected").
                "mtime_nsec": md.mtime_nsec(),
                "mode": md.mode(),
                "symlink": ft.is_symlink(),
                "target": target,
            })
        }
        Err(_) => Value::Null,
    }
}

fn dir_entry_value(name: &str, p: &Path) -> Value {
    let mut v = stat_value(p);
    if v.is_null() {
        v = json!({"kind": "file", "size": 0, "mtime": 0, "mode": 0, "symlink": false, "target": null});
    }
    if let Value::Object(ref mut m) = v {
        m.insert("name".into(), json!(name));
    }
    v
}

/// Streams a directory's listing (names + full lstat attrs) as one or more
/// chunked replies under ID, instead of building one potentially-huge `Vec`
/// and returning it in a single message. Sends `{"more": true, "entries":
/// [...]}` for each full batch, then a final message (no `more` key) that
/// also carries the directory's own attrs — notably its own mtime, which
/// changes whenever an entry is added/removed/renamed within it but not
/// when a file's own content changes; the Elisp side uses that to cheaply
/// revalidate a listing it kept from before a reconnect. Computed once, on
/// the final message only, not repeated per chunk.
///
/// A directory that can't even be opened sends a single ordinary error
/// reply via `finish` — no stream, no new failure shape for that case.
/// Individual entries that error mid-iteration are silently dropped
/// (`rd.flatten()`), matching the previous single-shot behavior — one bad
/// entry doesn't abort the whole listing.
fn readdir_stream(path: &str, tx: &SyncSender<Vec<u8>>, id: i64) {
    let rd = match fs::read_dir(path) {
        Ok(rd) => rd,
        Err(e) => {
            framing::finish(tx, id, Err(format!("readdir: {e}")));
            return;
        }
    };
    // Captured now, before consuming the iterator — not after, which was a
    // real bug caught by review: for a large directory (exactly the case
    // chunking exists for), the directory can change *during* enumeration.
    // The Elisp side trusts a matching `self_attrs.mtime' on reconnect to
    // mean "the cached entries are still accurate, skip re-fetching" — a
    // post-enumeration mtime would reflect the *end* state while `entries'
    // reflects whatever was seen along the way, so a later stat could match
    // that already-includes-the-change mtime and wrongly conclude "still
    // fresh," serving a stale/incomplete listing indefinitely. Capturing it
    // here means any mid-enumeration change makes the mtime-key stale too,
    // which is the correct, safe direction to be wrong in — it just costs a
    // real re-fetch next time instead of silently trusting bad data.
    let self_attrs = stat_value(Path::new(path));
    let mut batch = Vec::with_capacity(READDIR_CHUNK_SIZE);
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        batch.push(dir_entry_value(&name, &entry.path()));
        if batch.len() >= READDIR_CHUNK_SIZE {
            let chunk = std::mem::replace(&mut batch, Vec::with_capacity(READDIR_CHUNK_SIZE));
            let sent = tx.send(
                json!({"id": id, "ok": true, "more": true, "entries": chunk})
                    .to_string()
                    .into_bytes(),
            );
            if sent.is_err() {
                // Receiver (the writer thread) is gone -- the connection
                // closed. Stop iterating a possibly-huge directory for no
                // one rather than running the rest of this loop to
                // completion regardless.
                return;
            }
        }
    }
    // Final message: whatever's left in `batch` (possibly empty, for an
    // already-empty or exact-multiple-of-chunk-size directory), plus the
    // directory's own attrs. `send` doesn't add id/ok the way `finish`
    // does (that helper is specifically for the single-reply Result
    // case) — include them directly here, same as the streamed chunks
    // above, and omit `more` entirely so the Elisp dispatcher's
    // `(plist-get msg :more)` check reads this as the final message.
    send(
        tx,
        json!({"id": id, "ok": true, "entries": batch, "self_attrs": self_attrs}),
    );
}

/// Resolve symlinks + return attrs in one round-trip (avoids the per-segment
/// cascade Emacs's file-truename would otherwise cause). Does NOT also
/// enumerate the parent directory: an earlier version did, to prewarm it,
/// but the Elisp side never used that data (confirmed dead: grepped for
/// `parent_entries` and it wasn't read anywhere) — it just meant every
/// `file-truename` call (which fires on essentially every `find-file') did a
/// full parent-directory lstat sweep for nothing. Verified: opening one file
/// in a 5000-entry directory used to trigger this twice.
fn resolve(path: &str) -> Result<Value, String> {
    let real = fs::canonicalize(path).map_err(|e| format!("resolve: {e}"))?;
    let attrs = stat_value(&real);
    Ok(json!({
        "realpath": real.to_string_lossy(),
        "attrs": attrs,
    }))
}

/// Runs `command` (argv, program name first — NEVER a shell string) and
/// returns its exit code plus captured stdout/stderr, base64-encoded for the
/// same binary-safety reason file reads/writes already are.
///
/// `cwd`, if present, is expanded via `expand_home` and set on the child
/// (mirroring how other ops expand `~` in `path`); if absent, the child
/// inherits this server process's own working directory. `timeout_ms`
/// defaults to `DEFAULT_EXEC_TIMEOUT_MS` when omitted. A child that outlives
/// its timeout is killed and this returns `Err` promptly — it never
/// occupies this worker thread indefinitely, even if the direct child left
/// behind a grandchild holding its stdout/stderr pipes open (see the
/// timeout branch below for why that case must NOT join the drain
/// threads). The same grandchild scenario is also guarded on the ordinary
/// success path: the direct child can exit (via `try_wait`) while a
/// grandchild it backgrounded (e.g. `cmd &`, a detached `tmux` session)
/// still holds stdout/stderr open. Collecting the drain threads' output on
/// that path is bounded by the *remaining* `timeout_ms` budget, floored at
/// `EXEC_COLLECT_GRACE_MS` (via a channel + `recv_timeout`, not an
/// unconditional `join`), so total time is bounded by `timeout_ms` plus
/// that small fixed grace — not by however long a lingering grandchild
/// lives — on both the timeout and success paths.
fn exec_command(req: &Value) -> Result<Value, String> {
    let command = req
        .get("command")
        .and_then(Value::as_array)
        .ok_or_else(|| "exec: missing or non-array \"command\"".to_string())?;
    if command.is_empty() {
        return Err("exec: \"command\" must not be empty".into());
    }
    let argv: Vec<String> = command
        .iter()
        .map(|v| v.as_str().map(str::to_string))
        .collect::<Option<Vec<String>>>()
        .ok_or_else(|| "exec: \"command\" must be an array of strings".to_string())?;

    let timeout_ms = req
        .get("timeout_ms")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_EXEC_TIMEOUT_MS);

    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    if let Some(cwd) = req.get("cwd").and_then(Value::as_str) {
        cmd.current_dir(expand_home(cwd));
    }
    // Explicit, not incidental: `Command`'s default is to *inherit* the
    // parent's stdio when a stream isn't overridden. This server's own
    // stdin/stdout are the framed RPC protocol stream — silently inheriting
    // them into an arbitrary child would let it consume protocol bytes or
    // write raw bytes into a framed stream expecting length-prefixed JSON.
    // stdin is closed rather than piped: nothing in this synchronous
    // request/reply primitive ever sends a child bytes.
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("exec: spawn failed: {e}"))?;

    // Drain stdout/stderr on their own threads, concurrently with the
    // try_wait poll loop below, rather than reading only after the child
    // exits. A child that writes enough output to fill its pipe's kernel
    // buffer before exiting would otherwise block forever on that write if
    // nothing reads until after `wait()` returns — which would defeat the
    // timeout below entirely (the worker thread would still hang, just
    // blocked inside the child's write() instead of our poll loop).
    // Each reader thread reports its collected buffer back over a channel,
    // rather than as its `JoinHandle` return value. That lets the caller
    // collect the result with `recv_timeout` (bounded by the remaining
    // timeout budget) instead of an unconditional, unbounded `join` — see
    // the success path below, which needs exactly that to stay bounded
    // when a grandchild is still holding the pipe open.
    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();
    let (stdout_tx, stdout_rx) = mpsc::channel();
    let (stderr_tx, stderr_rx) = mpsc::channel();
    let stdout_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(p) = stdout_pipe.as_mut() {
            let _ = p.read_to_end(&mut buf);
        }
        let _ = stdout_tx.send(buf);
    });
    let stderr_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(p) = stderr_pipe.as_mut() {
            let _ = p.read_to_end(&mut buf);
        }
        let _ = stderr_tx.send(buf);
    });

    let start = Instant::now();
    let timeout = Duration::from_millis(timeout_ms);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("exec: wait failed: {e}"));
            }
        }
    };

    let Some(status) = status else {
        // Do NOT join the drain threads here. Killing the direct child only
        // closes *its* end of the pipes; if it forked a grandchild that
        // inherited stdout/stderr (e.g. backgrounded a process, `sh -c
        // "cmd &"`), that grandchild can keep the write end open long after
        // `kill()`/`wait()` return, and `read_to_end` blocks until its own
        // EOF -- so joining here would reintroduce exactly the hang the
        // timeout exists to prevent. Dropping the `JoinHandle`s detaches
        // those threads instead; their buffers are being discarded on this
        // path anyway.
        return Err(format!("exec: timed out after {timeout_ms}ms, process killed"));
    };

    // The same residual exposure applies here on the *success* path: if the
    // child left behind a grandchild still holding these pipes open,
    // waiting for the drain threads to see EOF can block past the child's
    // own exit for as long as that grandchild lives. Bound that wait by
    // whatever remains of the original `timeout_ms` window (computed from
    // the same `start`/`timeout` the poll loop above already tracks, not a
    // second independent clock) rather than an unconditional `join`. The
    // remaining budget is floored at `EXEC_COLLECT_GRACE_MS`: `try_wait()`
    // is only polled every 20ms, so it can observe success with ~0ms of
    // nominal budget left even though the reader thread (racing
    // concurrently this whole time) is a `recv` away from delivering
    // output it already finished reading -- without the floor that would
    // spuriously report a timeout for a command that truly succeeded. If
    // either stream still doesn't report back within that floored budget,
    // this is exactly the same situation the timeout branch above handles
    // -- the child is already gone (nothing left to `kill()`), so just
    // detach whichever reader thread(s) haven't finished (dropping their
    // `JoinHandle`s) and return the same timeout error, so a lingering
    // grandchild can never block this worker thread indefinitely on either
    // path.
    let remaining = timeout
        .saturating_sub(start.elapsed())
        .max(Duration::from_millis(EXEC_COLLECT_GRACE_MS));
    let stdout = match stdout_rx.recv_timeout(remaining) {
        Ok(buf) => buf,
        Err(_) => {
            return Err(format!("exec: timed out after {timeout_ms}ms, process killed"));
        }
    };
    let remaining = timeout
        .saturating_sub(start.elapsed())
        .max(Duration::from_millis(EXEC_COLLECT_GRACE_MS));
    let stderr = match stderr_rx.recv_timeout(remaining) {
        Ok(buf) => buf,
        Err(_) => {
            return Err(format!("exec: timed out after {timeout_ms}ms, process killed"));
        }
    };
    // Both channels reported in time: the drain threads have already
    // finished (each thread only sends after `read_to_end` returns), so
    // there's nothing left to join.
    let _ = stdout_thread;
    let _ = stderr_thread;

    Ok(json!({
        "exit_code": status.code(),
        "stdout_b64": B64.encode(&stdout),
        "stderr_b64": B64.encode(&stderr),
    }))
}

fn write_file(path: &str, b64: &str, append: bool, must_be_new: bool) -> Result<(), String> {
    let bytes = B64.decode(b64).map_err(|e| format!("write decode: {e}"))?;
    if must_be_new {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| format!("write(create new): {e}"))?;
        f.write_all(&bytes)
            .map_err(|e| format!("write(create new): {e}"))
    } else if append {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("write(open append): {e}"))?;
        f.write_all(&bytes).map_err(|e| format!("write(append): {e}"))
    } else {
        fs::write(path, bytes).map_err(|e| format!("write: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("relay-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn create_only_write_is_atomic() {
        let path = temp_path("must-be-new");
        let encoded = B64.encode(b"first");
        write_file(path.to_str().unwrap(), &encoded, false, true).unwrap();
        assert!(write_file(path.to_str().unwrap(), &encoded, false, true).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"first");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn revision_read_rejects_oversized_sparse_file_before_allocation() {
        let path = temp_path("oversized-read");
        let file = fs::File::create(&path).unwrap();
        file.set_len(16 * 1024 * 1024 + 1).unwrap();
        assert_eq!(
            revisions::read_with_revision(&path),
            Err(revisions::RevisionError::TooLarge)
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn exec_captures_stdout_and_reports_zero_exit() {
        let req = json!({"command": ["echo", "hello"]});
        let result = exec_command(&req).unwrap();
        assert_eq!(result["exit_code"], json!(0));
        let stdout = B64
            .decode(result["stdout_b64"].as_str().unwrap())
            .unwrap();
        assert_eq!(String::from_utf8(stdout).unwrap(), "hello\n");
        let stderr = B64
            .decode(result["stderr_b64"].as_str().unwrap())
            .unwrap();
        assert!(stderr.is_empty());
    }

    #[test]
    fn exec_reports_nonzero_exit_code() {
        // An explicit two-element argv naming `sh` as the program is not the
        // same thing as this server building a shell string itself -- WE
        // never interpolate `command` through a shell; the test just picks a
        // target program that's a convenient way to produce a specific exit
        // code and some stderr output.
        let req = json!({"command": ["sh", "-c", "echo oops 1>&2; exit 3"]});
        let result = exec_command(&req).unwrap();
        assert_eq!(result["exit_code"], json!(3));
        let stderr = B64
            .decode(result["stderr_b64"].as_str().unwrap())
            .unwrap();
        assert_eq!(String::from_utf8(stderr).unwrap(), "oops\n");
    }

    #[test]
    fn exec_missing_or_empty_command_is_rejected() {
        assert!(exec_command(&json!({})).is_err());
        assert!(exec_command(&json!({"command": []})).is_err());
        assert!(exec_command(&json!({"command": "echo hi"})).is_err());
        assert!(exec_command(&json!({"command": ["echo", 1]})).is_err());
    }

    #[test]
    fn exec_kills_a_hung_child_at_the_timeout_instead_of_hanging_the_test() {
        let start = Instant::now();
        let req = json!({"command": ["sleep", "5"], "timeout_ms": 200});
        let result = exec_command(&req);
        let elapsed = start.elapsed();
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("timed out"));
        // Generous upper bound so a loaded CI box isn't flaky, while still
        // proving this did not wait anywhere near the child's own 5s sleep.
        assert!(elapsed < Duration::from_secs(3), "elapsed = {elapsed:?}");
    }

    #[test]
    fn exec_timeout_does_not_hang_when_a_grandchild_keeps_the_pipes_open() {
        // The direct child here (`sh`) backgrounds a grandchild (the first
        // `sleep 5 &`) that inherits its stdout/stderr and then exits
        // itself only after ITS OWN 5s sleep -- so killing the direct
        // child does not close the grandchild's copy of the pipe write
        // ends. This reproduces the exact case the timeout branch's "do
        // not join the drain threads" comment exists for: a naive
        // join-then-check-timeout ordering would block here for as long
        // as the grandchild lives (~5s), not the requested 200ms.
        let start = Instant::now();
        let req = json!({"command": ["sh", "-c", "sleep 5 & sleep 5"], "timeout_ms": 200});
        let result = exec_command(&req);
        let elapsed = start.elapsed();
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("timed out"));
        assert!(elapsed < Duration::from_secs(2), "elapsed = {elapsed:?}");
    }

    #[test]
    fn exec_timeout_bounds_a_fast_exiting_parent_with_a_lingering_grandchild() {
        // Unlike the test above, the *direct* child here (`sh`) exits
        // almost immediately after backgrounding the grandchild (`sleep
        // 4`) -- so `try_wait` sees a successful exit well within the
        // 500ms timeout and the poll loop's timeout branch never fires.
        // The grandchild still inherited stdout/stderr, though, and keeps
        // those pipe write-ends open for its own 4s sleep. Before the fix,
        // the success path's unconditional `join` on the drain threads
        // blocked for that entire ~4s, completely ignoring `timeout_ms`.
        // This reproduces that exact shape and proves it's now bounded.
        let start = Instant::now();
        let req = json!({"command": ["sh", "-c", "sleep 4 & exit 0"], "timeout_ms": 500});
        let result = exec_command(&req);
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(1500),
            "elapsed = {elapsed:?} (should be bounded by timeout_ms, not the grandchild's 4s sleep)"
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("timed out"));
    }
}

/// Filesystem operations: read, write, stat, readdir, resolve, etc.
///
/// These run in a bounded worker pool so slow content ops never head-of-line-block metadata ops.

use crate::framing::{self, expand_home, finish_revision, send};
use crate::revisions;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::mpsc::SyncSender;

/// Chunk size for streaming `readdir` replies. Not client-configurable for
/// this first cut — a plain constant is enough to fix the actual problem
/// (no giant single blob, no unbounded buffer before the first byte).
const READDIR_CHUNK_SIZE: usize = 2000;

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
}

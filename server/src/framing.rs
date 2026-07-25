/// Wire protocol helpers: framing, size limits, and home expansion.
///
/// Framing: 4-byte little-endian length prefix + UTF-8 JSON payload, both ways.
/// File bytes are base64 (`read`/`write`). See docs/M0-async-file-layer.md.

use crate::revisions;
use serde_json::Value;
use std::sync::mpsc::SyncSender;

// These limits protect the long-lived server from a malformed peer or a burst
// of expensive requests.  They are intentionally generous enough for normal
// text/source work while making memory and thread use predictable.
pub(crate) const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;

pub(crate) fn frame_size_allowed(size: usize) -> bool {
    size <= MAX_FRAME_BYTES
}

/// Expand the remote account's own `~' shorthand without involving a shell.
/// Only `~' and `~/' are supported; `~other' remains a literal path.
pub(crate) fn expand_home(path: &str) -> String {
    if path == "~" || path.starts_with("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            let mut expanded = std::path::PathBuf::from(home);
            if let Some(rest) = path.strip_prefix("~/") {
                expanded.push(rest);
            }
            return expanded.to_string_lossy().to_string();
        }
    }
    path.to_string()
}

pub(crate) fn send(tx: &SyncSender<Vec<u8>>, v: Value) {
    let payload = v.to_string().into_bytes();
    if payload.len() <= MAX_FRAME_BYTES {
        let _ = tx.send(payload);
    }
}

pub(crate) fn finish(tx: &SyncSender<Vec<u8>>, id: i64, result: Result<Value, String>) {
    match result {
        Ok(mut v) => {
            if let Value::Object(ref mut m) = v {
                m.insert("id".into(), serde_json::json!(id));
                m.insert("ok".into(), serde_json::json!(true));
            }
            send(tx, v);
        }
        Err(e) => send(tx, serde_json::json!({ "id": id, "ok": false, "error": e })),
    }
}

pub(crate) fn finish_revision(
    tx: &SyncSender<Vec<u8>>,
    id: i64,
    result: Result<Value, revisions::RevisionError>,
) {
    match result {
        Ok(mut value) => {
            if let Value::Object(ref mut object) = value {
                object.insert("id".into(), serde_json::json!(id));
                object.insert("ok".into(), serde_json::json!(true));
            }
            send(tx, value);
        }
        Err(error) => {
            let mut value = revisions::wire_error(&error);
            if let Value::Object(ref mut object) = value {
                object.insert("id".into(), serde_json::json!(id));
            }
            send(tx, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_size_limit_rejects_oversized_frames() {
        assert!(frame_size_allowed(MAX_FRAME_BYTES));
        assert!(!frame_size_allowed(MAX_FRAME_BYTES + 1));
    }

    #[test]
    fn expands_the_server_accounts_home_shorthand() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expand_home("~"), home);
        assert_eq!(expand_home("~/project"), format!("{home}/project"));
        assert_eq!(expand_home("~other/project"), "~other/project");
    }
}

//! Descriptor-stable revisions and atomic conditional file replacement.

mod types;
mod read;
mod write;
#[cfg(test)]
mod tests;

use serde_json::{Value, json};
use std::sync::{Mutex, MutexGuard, OnceLock};

// Re-export public items so external code can use revisions::TypeName
pub(crate) use types::{
    Revision, ExpectedRevision, ConditionalWrite, RevisionError,
};
pub(crate) use read::{read_range, read_with_revision};

const MAX_READ_BYTES: u64 = 16 * 1024 * 1024;
const READ_ATTEMPTS: usize = 3;
static MUTATION_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Serialize every server-side filesystem mutation.  This is process-wide,
/// which is exactly the scope of the framed server and prevents two workers
/// from accepting the same expected revision concurrently.
pub(crate) fn mutation_guard() -> MutexGuard<'static, ()> {
    MUTATION_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Atomically replace `path` only when its current revision exactly equals
/// `expected`. `Missing` is a create-only expectation.
pub(crate) fn conditional_write(
    path: &std::path::Path,
    bytes: &[u8],
    expected: &ExpectedRevision,
) -> Result<ConditionalWrite, RevisionError> {
    let _guard = mutation_guard();
    write::conditional_write_locked(path, bytes, expected)
}

/// JSON error shape for revision protocol errors. Conflicts retain an ordinary
/// readable `error` while giving clients the machine-readable snapshot needed
/// to drive a three-way resolution UI.
pub(crate) fn wire_error(error: &RevisionError) -> Value {
    match error {
        RevisionError::Conflict {
            kind,
            current_revision,
        } => json!({
            "ok": false,
            "error_code": "conflict",
            "error": error.readable(),
            "conflict": {
                "kind": kind.wire_name(),
                "current_revision": current_revision.as_ref().map(Revision::to_value),
            },
        }),
        RevisionError::UnstableRead => {
            json!({"ok": false, "error_code": "unstable_read", "error": error.readable()})
        }
        RevisionError::UnsupportedFinalType(_) => json!({
            "ok": false,
            "error_code": "unsupported_file_type",
            "error": error.readable(),
        }),
        RevisionError::UnsupportedEncoding => json!({
            "ok": false,
            "error_code": "unsupported_encoding",
            "error": error.readable(),
        }),
        RevisionError::TooLarge => {
            json!({"ok": false, "error_code": "file_too_large", "error": error.readable()})
        }
        RevisionError::Io(_) => json!({"ok": false, "error_code": "io", "error": error.readable()}),
    }
}

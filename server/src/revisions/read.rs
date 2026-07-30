/// Read path: establishing stable file descriptors and their revision tokens.

use crate::revisions::{MAX_READ_BYTES, READ_ATTEMPTS};
use super::types::{
    RevisionError, RevisionRead, Revision, final_type, io_error, metadata_equal, open_checked, sha256,
};
use std::io::{Read as _, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

fn read_with_revision_hook<F>(
    path: &Path,
    mut between_samples: F,
) -> Result<RevisionRead, RevisionError>
where
    F: FnMut(),
{
    for _ in 0..READ_ATTEMPTS {
        let mut file = open_checked(path)?;
        let before = file.metadata().map_err(|error| io_error("read", error))?;
        if let Some(kind) = final_type(&before) {
            return Err(RevisionError::UnsupportedFinalType(kind));
        }
        if before.size() > MAX_READ_BYTES {
            return Err(RevisionError::TooLarge);
        }

        let mut bytes = Vec::with_capacity(before.size() as usize);
        std::io::Read::by_ref(&mut file)
            .take(MAX_READ_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|error| io_error("read", error))?;
        if bytes.len() as u64 > MAX_READ_BYTES {
            return Err(RevisionError::TooLarge);
        }
        let sha256 = sha256(&bytes);
        between_samples();
        let after = file.metadata().map_err(|error| io_error("read", error))?;
        if let Some(kind) = final_type(&after) {
            return Err(RevisionError::UnsupportedFinalType(kind));
        }
        if metadata_equal(&before, &after) {
            if std::str::from_utf8(&bytes).is_err() {
                return Err(RevisionError::UnsupportedEncoding);
            }
            return Ok(RevisionRead {
                bytes,
                revision: Revision::from_metadata(&after, sha256),
            });
        }
    }
    Err(RevisionError::UnstableRead)
}

/// Read bytes and a revision from one stable descriptor, retrying an unstable
/// read three times rather than handing a client an uncertain save base.
pub(crate) fn read_with_revision(path: &Path) -> Result<RevisionRead, RevisionError> {
    read_with_revision_hook(path, || {})
}

/// Read one bounded byte range from a stable descriptor. Unlike the full
/// revision read, this intentionally does not hash the whole file: callers
/// use it for tail/history transfer, not for establishing a save BASE.
pub(crate) fn read_range(path: &Path, start: u64, end: u64) -> Result<Vec<u8>, RevisionError> {
    const MAX_RANGE_BYTES: u64 = 1024 * 1024;
    if end < start || end - start > MAX_RANGE_BYTES {
        return Err(RevisionError::TooLarge);
    }
    for _ in 0..READ_ATTEMPTS {
        let mut file = open_checked(path)?;
        let before = file.metadata().map_err(|error| io_error("read_range", error))?;
        if let Some(kind) = final_type(&before) {
            return Err(RevisionError::UnsupportedFinalType(kind));
        }
        let file_size = before.size();
        let actual_end = end.min(file_size);
        if start > actual_end {
            return Ok(Vec::new());
        }
        file.seek(SeekFrom::Start(start))
            .map_err(|error| io_error("read_range", error))?;
        let mut bytes = Vec::with_capacity((actual_end - start) as usize);
        file.by_ref().take(actual_end - start)
            .read_to_end(&mut bytes)
            .map_err(|error| io_error("read_range", error))?;
        let after = file.metadata().map_err(|error| io_error("read_range", error))?;
        if metadata_equal(&before, &after) {
            return Ok(bytes);
        }
    }
    Err(RevisionError::UnstableRead)
}

/// One `tail_read` reply. See `tail_read`'s docstring for field semantics.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TailRead {
    pub bytes: Vec<u8>,
    pub start: u64,
    pub actual_end: u64,
    pub file_size: u64,
    pub dev: u64,
    pub ino: u64,
    pub truncated_or_rotated: bool,
    pub more_available: bool,
}

/// Largest single `tail_read` reply. Matches `read_range`'s bound for now;
/// raising it (README-LATENCY.md notes Muster's chunking need can exceed
/// this) is separate follow-up work, not required for this op to be correct.
const MAX_TAIL_BYTES: u64 = 1024 * 1024;

/// Read an append-tolerant snapshot tail: bytes from KNOWN_OFFSET through
/// EOF as observed by one stat, capped at MAX_BYTES.
///
/// Unlike `read_range`, this does not retry when the file changes during the
/// read and does not compare metadata before/after: an append arriving after
/// the snapshot is not an error (the next call picks it up), and requiring
/// before/after equality is exactly the bug this op exists to avoid -- see
/// README-LATENCY.md's "Range consistency on append" finding. The only
/// re-anchor conditions are ones a plain retry cannot fix: identity change
/// (KNOWN_DEV/KNOWN_INO, when the caller supplies them, no longer match --
/// rotation) or KNOWN_OFFSET no longer being a valid prefix of the current
/// file (it shrank -- truncation). Either sets `truncated_or_rotated` and
/// re-anchors the read at offset 0 rather than erroring, so callers get
/// real bytes back and a clear signal to discard buffered partial state,
/// instead of having to retry themselves after an error.
///
/// `actual_end` always describes the bytes actually returned (`start +
/// bytes.len()`), never the requested end -- a concurrent truncation mid-read
/// can make the real read shorter than MAX_BYTES even without triggering the
/// pre-read `truncated_or_rotated` check (which only inspects the pre-read
/// stat); the caller's own next call re-stats fresh and self-corrects.
pub(crate) fn tail_read(
    path: &Path,
    known_offset: u64,
    known_dev: Option<u64>,
    known_ino: Option<u64>,
    max_bytes: u64,
) -> Result<TailRead, RevisionError> {
    let max_bytes = max_bytes.min(MAX_TAIL_BYTES);
    let mut file = open_checked(path)?;
    let metadata = file.metadata().map_err(|error| io_error("tail_read", error))?;
    if let Some(kind) = final_type(&metadata) {
        return Err(RevisionError::UnsupportedFinalType(kind));
    }
    let file_size = metadata.size();
    let dev = metadata.dev();
    let ino = metadata.ino();

    let identity_changed =
        known_dev.is_some_and(|d| d != dev) || known_ino.is_some_and(|i| i != ino);
    let shrunk = known_offset > file_size;
    let truncated_or_rotated = identity_changed || shrunk;
    let start = if truncated_or_rotated { 0 } else { known_offset };
    let want_end = start.saturating_add(max_bytes).min(file_size);

    let mut bytes = Vec::new();
    if start < want_end {
        file.seek(SeekFrom::Start(start))
            .map_err(|error| io_error("tail_read", error))?;
        bytes.reserve((want_end - start) as usize);
        file.by_ref()
            .take(want_end - start)
            .read_to_end(&mut bytes)
            .map_err(|error| io_error("tail_read", error))?;
    }
    let actual_end = start + bytes.len() as u64;
    Ok(TailRead {
        bytes,
        start,
        actual_end,
        file_size,
        dev,
        ino,
        truncated_or_rotated,
        more_available: actual_end < file_size,
    })
}

/// Test seam for deterministically changing a file between descriptor metadata
/// samples.  It will become private to the test module once real read logic is
/// in place.
#[cfg(test)]
pub(crate) fn read_with_revision_between_samples<F>(
    path: &Path,
    between_samples: F,
) -> Result<RevisionRead, RevisionError>
where
    F: FnMut(),
{
    read_with_revision_hook(path, between_samples)
}

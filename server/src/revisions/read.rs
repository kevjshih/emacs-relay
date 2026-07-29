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

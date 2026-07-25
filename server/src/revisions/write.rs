/// Write path: conditional writes with conflict detection.

use crate::revisions::MAX_READ_BYTES;
#[cfg(test)]
use crate::revisions::mutation_guard;
use super::read::read_with_revision;
use super::types::{
    ConditionalWrite, ConflictKind, ExpectedRevision, RevisionError, checked_lstat,
    final_type, io_error,
};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

struct PendingTemp {
    path: PathBuf,
    active: bool,
}

impl PendingTemp {
    fn new(directory: &Path) -> Result<(Self, File), RevisionError> {
        for _ in 0..100 {
            let serial = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = directory.join(format!(".relay-tmp-{}-{serial}", std::process::id()));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => return Ok((Self { path, active: true }, file)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(io_error("write(temp)", error)),
            }
        }
        Err(RevisionError::Io(
            "write(temp): exhausted unique temporary names".into(),
        ))
    }

    fn keep_after_rename(&mut self) {
        self.active = false;
    }
}

impl Drop for PendingTemp {
    fn drop(&mut self) {
        if self.active {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn preserve_metadata(temp: &File, original: Option<&fs::Metadata>) -> Result<(), RevisionError> {
    let Some(original) = original else {
        return Ok(());
    };
    // In the usual case the newly-created file already has this owner.  If a
    // server is privileged enough to preserve a different owner, do so; if it
    // is not, fail safely rather than replacing a file with altered ownership.
    let result = unsafe { libc::fchown(temp.as_raw_fd(), original.uid(), original.gid()) };
    if result != 0 {
        return Err(io_error(
            "write(set ownership)",
            std::io::Error::last_os_error(),
        ));
    }
    // Do this after fchown: ownership changes may clear set-id bits.
    temp.set_permissions(fs::Permissions::from_mode(original.mode() & 0o7777))
        .map_err(|error| io_error("write(set mode)", error))?;
    Ok(())
}

pub(super) fn conflict_for_existing(
    expected: &ExpectedRevision,
    path: &Path,
) -> Result<(), RevisionError> {
    match expected {
        ExpectedRevision::Missing => match checked_lstat(path)? {
            None => Ok(()),
            Some(metadata) => Err(missing_appearance_conflict(path, &metadata)?),
        },
        ExpectedRevision::Present(expected_revision) => {
            if !expected_revision.is_valid_file_revision() {
                return Err(RevisionError::Io("write: invalid expected revision".into()));
            }
            let metadata = match checked_lstat(path)? {
                None => {
                    return Err(RevisionError::Conflict {
                        kind: ConflictKind::Deleted,
                        current_revision: None,
                    });
                }
                Some(metadata) => metadata,
            };
            if let Some(kind) = final_type(&metadata) {
                return if kind == "hardlink" {
                    Err(RevisionError::UnsupportedFinalType(kind))
                } else {
                    Err(RevisionError::Conflict {
                        kind: ConflictKind::TypeChanged,
                        current_revision: None,
                    })
                };
            }
            let current = read_with_revision(path)?.revision;
            if &current == expected_revision {
                Ok(())
            } else {
                Err(RevisionError::Conflict {
                    kind: ConflictKind::Changed,
                    current_revision: Some(current),
                })
            }
        }
    }
}

/// Classify something that appeared where a missing-state save intended to
/// create. Non-regular paths are never opened; hard links retain their
/// explicit safety error, while type changes are machine-readable conflicts.
pub(super) fn missing_appearance_conflict(
    path: &Path,
    metadata: &fs::Metadata,
) -> Result<RevisionError, RevisionError> {
    if let Some(kind) = final_type(metadata) {
        return if kind == "hardlink" {
            Ok(RevisionError::UnsupportedFinalType(kind))
        } else {
            Ok(RevisionError::Conflict {
                kind: ConflictKind::TypeChanged,
                current_revision: None,
            })
        };
    }
    let current = read_with_revision(path)?.revision;
    Ok(RevisionError::Conflict {
        kind: ConflictKind::Appeared,
        current_revision: Some(current),
    })
}

pub(super) fn conditional_write_locked(
    path: &Path,
    bytes: &[u8],
    expected: &ExpectedRevision,
) -> Result<ConditionalWrite, RevisionError> {
    conditional_write_locked_with_hooks(path, bytes, expected, || {}, || {})
}

pub(super) fn conditional_write_locked_with_hooks<Before, After>(
    path: &Path,
    bytes: &[u8],
    expected: &ExpectedRevision,
    mut before_publish: Before,
    mut after_publish: After,
) -> Result<ConditionalWrite, RevisionError>
where
    Before: FnMut(),
    After: FnMut(),
{
    if bytes.len() as u64 > MAX_READ_BYTES {
        return Err(RevisionError::TooLarge);
    }
    if std::str::from_utf8(bytes).is_err() {
        return Err(RevisionError::UnsupportedEncoding);
    }
    conflict_for_existing(expected, path)?;
    let original = checked_lstat(path)?;
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    let (mut pending, mut temp) = PendingTemp::new(directory)?;
    preserve_metadata(&temp, original.as_ref())?;
    temp.write_all(bytes)
        .map_err(|error| io_error("write(temp)", error))?;
    temp.sync_all()
        .map_err(|error| io_error("write(sync)", error))?;

    // The second stable comparison closes the window while the temporary file
    // was being created and flushed.  No write happens after a stale check.
    conflict_for_existing(expected, path)?;
    before_publish();
    match expected {
        ExpectedRevision::Present(_) => {
            fs::rename(&pending.path, path).map_err(|error| io_error("write(rename)", error))?;
            pending.keep_after_rename();
        }
        ExpectedRevision::Missing => match fs::hard_link(&pending.path, path) {
            Ok(()) => {
                // Link is atomic no-replace. Removing the temporary name leaves
                // the new destination as the sole link to its flushed inode.
                fs::remove_file(&pending.path)
                    .map_err(|error| io_error("write(publish cleanup)", error))?;
                pending.keep_after_rename();
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let metadata = checked_lstat(path)?.ok_or_else(|| {
                    RevisionError::Io(
                        "write(publish): destination disappeared after collision".into(),
                    )
                })?;
                return Err(missing_appearance_conflict(path, &metadata)?);
            }
            Err(error) => return Err(io_error("write(publish missing)", error)),
        },
    }
    after_publish();
    let published = read_with_revision(path)?;
    if published.bytes != bytes {
        return Err(RevisionError::Conflict {
            kind: ConflictKind::Changed,
            current_revision: Some(published.revision),
        });
    }
    Ok(ConditionalWrite {
        revision: published.revision,
    })
}

/// Deterministic test seam for the external-creator window after the second
/// check and before publication. Production calls never install a hook.
#[cfg(test)]
pub(crate) fn conditional_write_before_publish<F>(
    path: &Path,
    bytes: &[u8],
    expected: &ExpectedRevision,
    before_publish: F,
) -> Result<ConditionalWrite, RevisionError>
where
    F: FnMut(),
{
    let _guard = mutation_guard();
    conditional_write_locked_with_hooks(path, bytes, expected, before_publish, || {})
}

/// Deterministic test seam for an external replacement after a successful
/// publish but before the server has verified the returned revision.
#[cfg(test)]
pub(crate) fn conditional_write_after_publish<F>(
    path: &Path,
    bytes: &[u8],
    expected: &ExpectedRevision,
    after_publish: F,
) -> Result<ConditionalWrite, RevisionError>
where
    F: FnMut(),
{
    let _guard = mutation_guard();
    conditional_write_locked_with_hooks(path, bytes, expected, || {}, after_publish)
}

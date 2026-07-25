use super::types::*;
use super::read::*;
use super::write::*;
use super::conditional_write;
use std::fs::{self, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let serial = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "relay-revisions-{label}-{}-{nonce}-{serial}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn write(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
}

fn read_base(path: &Path) -> Revision {
    read_with_revision(path)
        .expect("revision reads must establish a stable base")
        .revision
}

fn assert_conflict(result: Result<ConditionalWrite, RevisionError>, kind: ConflictKind) {
    match result {
        Err(RevisionError::Conflict { kind: actual, .. }) => assert_eq!(
            actual, kind,
            "conditional write must describe the precise conflict kind"
        ),
        other => panic!("expected {kind:?} conflict, got {other:?}"),
    }
}

#[test]
fn read_bytes_and_revision_hash_agree() {
    let temp = TempDir::new("read-hash");
    let path = temp.file("note.txt");
    write(&path, b"revisioned bytes\n");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();

    let read = read_with_revision(&path).expect("read must succeed");
    assert_eq!(read.bytes, b"revisioned bytes\n");
    assert_eq!(read.revision.state, RevisionState::Present);
    assert_eq!(read.revision.kind, RevisionKind::File);
    assert_eq!(read.revision.size, read.bytes.len() as u64);
    assert_eq!(read.revision.mode, 0o640);
    assert_eq!(
        read.revision.sha256,
        "f7257470371d464f06b15b1e5ddff4277066de0828dd54daeee7e0e82725c01d"
    );
}

#[test]
fn sha256_known_vectors_cover_empty_and_multi_block_inputs() {
    assert_eq!(
        super::types::sha256(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        super::types::sha256(&vec![b'a'; 1000]),
        "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
    );
}

#[test]
fn malformed_expected_revisions_are_rejected_before_comparison() {
    let temp = TempDir::new("malformed-revision");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let revision = read_base(&path);
    let mut malformed = revision.to_value();
    malformed["schema"] = serde_json::json!(2);
    assert!(Revision::from_value(&malformed).is_err());
    malformed = revision.to_value();
    malformed["sha256"] = serde_json::json!("ABCDEF");
    assert!(Revision::from_value(&malformed).is_err());
    malformed = revision.to_value();
    malformed["mtime_nsec"] = serde_json::json!(1_000_000_000_i64);
    assert!(Revision::from_value(&malformed).is_err());
    malformed = revision.to_value();
    malformed["state"] = serde_json::json!("missing");
    assert!(Revision::from_value(&malformed).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"base");
}

#[test]
fn changing_during_read_refuses_to_establish_a_base() {
    let temp = TempDir::new("unstable-read");
    let path = temp.file("note.txt");
    write(&path, b"before");

    let result = read_with_revision_between_samples(&path, || write(&path, b"after"));
    assert_eq!(result, Err(RevisionError::UnstableRead));
}

#[test]
fn matching_conditional_write_succeeds_and_returns_a_new_revision() {
    let temp = TempDir::new("write-success");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let base = read_base(&path);

    let saved = conditional_write(&path, b"local", &ExpectedRevision::Present(base.clone()))
        .expect("matching revision must save");
    assert_eq!(fs::read(&path).unwrap(), b"local");
    assert_ne!(saved.revision, base);
    assert_eq!(saved.revision.sha256.len(), 64);
}

#[test]
fn stale_conditional_write_leaves_remote_bytes_untouched() {
    let temp = TempDir::new("stale-write");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let base = read_base(&path);
    write(&path, b"remote");

    assert_conflict(
        conditional_write(&path, b"local", &ExpectedRevision::Present(base)),
        ConflictKind::Changed,
    );
    assert_eq!(fs::read(&path).unwrap(), b"remote");
}

#[test]
fn delete_recreate_identical_bytes_conflicts_by_identity() {
    let temp = TempDir::new("replace-identity");
    let path = temp.file("note.txt");
    write(&path, b"same bytes");
    let base = read_base(&path);
    let original_ino = fs::metadata(&path).unwrap().ino();
    fs::remove_file(&path).unwrap();
    write(&path, b"same bytes");
    assert_ne!(fs::metadata(&path).unwrap().ino(), original_ino);

    assert_conflict(
        conditional_write(&path, b"local", &ExpectedRevision::Present(base)),
        ConflictKind::Changed,
    );
    assert_eq!(fs::read(&path).unwrap(), b"same bytes");
}

#[test]
fn missing_present_and_type_changed_have_distinct_conflicts() {
    let temp = TempDir::new("conflict-kinds");
    let deleted = temp.file("deleted.txt");
    write(&deleted, b"base");
    let deleted_base = read_base(&deleted);
    fs::remove_file(&deleted).unwrap();
    assert_conflict(
        conditional_write(&deleted, b"local", &ExpectedRevision::Present(deleted_base)),
        ConflictKind::Deleted,
    );

    let appeared = temp.file("appeared.txt");
    write(&appeared, b"other process won");
    assert_conflict(
        conditional_write(&appeared, b"local", &ExpectedRevision::Missing),
        ConflictKind::Appeared,
    );

    let replaced = temp.file("replaced.txt");
    write(&replaced, b"base");
    let replaced_base = read_base(&replaced);
    fs::remove_file(&replaced).unwrap();
    fs::create_dir(&replaced).unwrap();
    assert_conflict(
        conditional_write(
            &replaced,
            b"local",
            &ExpectedRevision::Present(replaced_base),
        ),
        ConflictKind::TypeChanged,
    );
}

#[test]
fn two_same_revision_writes_have_exactly_one_winner() {
    let temp = TempDir::new("concurrent-write");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let base = read_base(&path);
    let barrier = Arc::new(Barrier::new(3));
    let mut workers = Vec::new();
    for bytes in [b"first".as_slice(), b"second".as_slice()] {
        let path = path.clone();
        let base = base.clone();
        let barrier = Arc::clone(&barrier);
        workers.push(thread::spawn(move || {
            barrier.wait();
            conditional_write(&path, bytes, &ExpectedRevision::Present(base))
        }));
    }
    barrier.wait();
    let successes = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .filter(Result::is_ok)
        .count();
    assert_eq!(successes, 1, "the mutation lock must admit one writer");
    assert!(matches!(
        fs::read(&path).unwrap().as_slice(),
        b"first" | b"second"
    ));
}

#[test]
fn two_missing_state_creates_have_exactly_one_winner() {
    let temp = TempDir::new("concurrent-create");
    let path = temp.file("new.txt");
    let barrier = Arc::new(Barrier::new(3));
    let mut workers = Vec::new();
    for bytes in [b"first".as_slice(), b"second".as_slice()] {
        let path = path.clone();
        let barrier = Arc::clone(&barrier);
        workers.push(thread::spawn(move || {
            barrier.wait();
            conditional_write(&path, bytes, &ExpectedRevision::Missing)
        }));
    }
    barrier.wait();
    let successes = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .filter(Result::is_ok)
        .count();
    assert_eq!(
        successes, 1,
        "missing-state conditional writes are create-only"
    );
    assert!(matches!(
        fs::read(&path).unwrap().as_slice(),
        b"first" | b"second"
    ));
}

#[test]
fn external_creator_in_final_missing_publish_window_is_never_overwritten() {
    let temp = TempDir::new("external-create-window");
    let path = temp.file("new.txt");
    let result =
        conditional_write_before_publish(&path, b"local", &ExpectedRevision::Missing, || {
            write(&path, b"external")
        });
    assert_conflict(result, ConflictKind::Appeared);
    assert_eq!(fs::read(&path).unwrap(), b"external");
    let leftovers: Vec<_> = fs::read_dir(&temp.0)
        .unwrap()
        .flatten()
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".relay-tmp-")
        })
        .collect();
    assert!(
        leftovers.is_empty(),
        "failed no-replace publish cleans its temp"
    );
}

#[test]
fn post_publish_replacement_never_reports_the_write_as_saved() {
    let temp = TempDir::new("post-publish-replacement");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let base = read_base(&path);

    let result = conditional_write_after_publish(
        &path,
        b"local",
        &ExpectedRevision::Present(base),
        || write(&path, b"external"),
    );
    assert_conflict(result, ConflictKind::Changed);
    assert_eq!(fs::read(&path).unwrap(), b"external");
}

#[test]
fn atomic_replacement_preserves_ordinary_mode_bits() {
    let temp = TempDir::new("mode");
    let path = temp.file("note.txt");
    write(&path, b"base");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
    let base = read_base(&path);

    conditional_write(&path, b"local", &ExpectedRevision::Present(base))
        .expect("matching save must preserve mode");
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o640);
}

#[test]
fn final_symlink_is_rejected_without_modification() {
    let temp = TempDir::new("unsafe-types");
    let target = temp.file("target.txt");
    write(&target, b"target");

    let symlink = temp.file("link");
    std::os::unix::fs::symlink(&target, &symlink).unwrap();
    assert_conflict(
        conditional_write(&symlink, b"local", &ExpectedRevision::Missing),
        ConflictKind::TypeChanged,
    );
    assert!(
        fs::symlink_metadata(&symlink)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(fs::read(&target).unwrap(), b"target");
}

#[test]
fn hardlinked_file_is_rejected_without_modification() {
    let temp = TempDir::new("unsafe-hardlink");
    let target = temp.file("target.txt");
    write(&target, b"target");
    let hardlink = temp.file("hardlink");
    let hardlink_base = read_base(&target);
    fs::hard_link(&target, &hardlink).unwrap();
    assert_eq!(
        conditional_write(&target, b"local", &ExpectedRevision::Present(hardlink_base)),
        Err(RevisionError::UnsupportedFinalType("hardlink"))
    );
    assert_eq!(fs::read(&target).unwrap(), b"target");
    assert_eq!(fs::read(&hardlink).unwrap(), b"target");
    assert_eq!(
        conditional_write(&hardlink, b"local", &ExpectedRevision::Missing),
        Err(RevisionError::UnsupportedFinalType("hardlink"))
    );
}

#[test]
fn directory_is_rejected_without_modification() {
    let temp = TempDir::new("unsafe-directory");
    let directory = temp.file("directory");
    fs::create_dir(&directory).unwrap();
    assert_conflict(
        conditional_write(&directory, b"local", &ExpectedRevision::Missing),
        ConflictKind::TypeChanged,
    );
    assert!(fs::metadata(&directory).unwrap().is_dir());
}

#[test]
fn fifo_is_rejected_without_modification() {
    let temp = TempDir::new("unsafe-fifo");
    let fifo = temp.file("fifo");
    let status = std::process::Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap();
    assert!(status.success());
    assert_conflict(
        conditional_write(&fifo, b"local", &ExpectedRevision::Missing),
        ConflictKind::TypeChanged,
    );
    assert_eq!(
        fs::symlink_metadata(&fifo).unwrap().mode() & 0o170000,
        0o010000
    );
}

#[test]
fn oversized_file_is_rejected_without_modification() {
    let temp = TempDir::new("oversized");
    let path = temp.file("large.bin");
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .unwrap();
    file.set_len(16 * 1024 * 1024 + 1).unwrap();
    assert_eq!(read_with_revision(&path), Err(RevisionError::TooLarge));
    assert_eq!(fs::metadata(&path).unwrap().len(), 16 * 1024 * 1024 + 1);
}

#[test]
fn invalid_utf8_read_and_write_are_rejected_without_modification() {
    let temp = TempDir::new("invalid-utf8");
    let binary = temp.file("binary.dat");
    write(&binary, &[0xff, 0xfe, 0xfd]);
    assert_eq!(
        read_with_revision(&binary),
        Err(RevisionError::UnsupportedEncoding)
    );
    assert_eq!(fs::read(&binary).unwrap(), [0xff, 0xfe, 0xfd]);

    let text = temp.file("text.txt");
    write(&text, b"base");
    let base = read_base(&text);
    assert_eq!(
        conditional_write(
            &text,
            &[0xff, 0xfe, 0xfd],
            &ExpectedRevision::Present(base)
        ),
        Err(RevisionError::UnsupportedEncoding)
    );
    assert_eq!(fs::read(&text).unwrap(), b"base");
}

#[test]
fn failed_write_cleans_its_temporary_files() {
    let temp = TempDir::new("temp-cleanup");
    let path = temp.file("note.txt");
    write(&path, b"base");
    let base = read_base(&path);
    write(&path, b"remote");

    let _ = conditional_write(&path, b"local", &ExpectedRevision::Present(base));
    let leftovers: Vec<_> = fs::read_dir(&temp.0)
        .unwrap()
        .flatten()
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".relay-tmp-")
        })
        .collect();
    assert!(
        leftovers.is_empty(),
        "failed atomic writes must remove temps"
    );
}

#[test]
fn structured_wire_conflicts_include_code_object_and_message() {
    let value = super::wire_error(&RevisionError::Conflict {
        kind: ConflictKind::Changed,
        current_revision: None,
    });
    assert_eq!(value.get("ok").and_then(serde_json::Value::as_bool), Some(false));
    assert_eq!(
        value.get("error_code").and_then(serde_json::Value::as_str),
        Some("conflict")
    );
    assert_eq!(
        value.pointer("/conflict/kind").and_then(serde_json::Value::as_str),
        Some("changed")
    );
    assert!(
        value
            .get("error")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|message| message.contains("conflict"))
    );
    let type_changed = super::wire_error(&RevisionError::Conflict {
        kind: ConflictKind::TypeChanged,
        current_revision: None,
    });
    assert_eq!(
        type_changed
            .pointer("/conflict/kind")
            .and_then(serde_json::Value::as_str),
        Some("type_changed")
    );
}

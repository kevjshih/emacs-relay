/// Core types and shared helpers for revision reads and writes.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

/// The exact identity and content facts a client uses as its save base.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Revision {
    pub schema: u8,
    pub state: RevisionState,
    pub kind: RevisionKind,
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub mtime_sec: i64,
    pub mtime_nsec: i64,
    pub ctime_sec: i64,
    pub ctime_nsec: i64,
    pub mode: u32,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RevisionState {
    Present,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RevisionKind {
    File,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ExpectedRevision {
    Present(Revision),
    Missing,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RevisionRead {
    pub bytes: Vec<u8>,
    pub revision: Revision,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConditionalWrite {
    pub revision: Revision,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ConflictKind {
    Changed,
    Deleted,
    Appeared,
    TypeChanged,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RevisionError {
    UnstableRead,
    Conflict {
        kind: ConflictKind,
        current_revision: Option<Revision>,
    },
    UnsupportedFinalType(&'static str),
    UnsupportedEncoding,
    TooLarge,
    Io(String),
}

impl Revision {
    pub(super) fn from_metadata(metadata: &fs::Metadata, sha256: String) -> Self {
        Self {
            schema: 1,
            state: RevisionState::Present,
            kind: RevisionKind::File,
            dev: metadata.dev(),
            ino: metadata.ino(),
            size: metadata.size(),
            mtime_sec: metadata.mtime(),
            mtime_nsec: metadata.mtime_nsec(),
            ctime_sec: metadata.ctime(),
            ctime_nsec: metadata.ctime_nsec(),
            // File type has its own `kind` field; expose the portable
            // permission/special-bit value rather than Unix's type bits.
            mode: metadata.mode() & 0o7777,
            sha256,
        }
    }

    pub(super) fn is_valid_file_revision(&self) -> bool {
        self.schema == 1
            && self.state == RevisionState::Present
            && self.kind == RevisionKind::File
            && self.mtime_nsec >= 0
            && self.mtime_nsec < 1_000_000_000
            && self.ctime_nsec >= 0
            && self.ctime_nsec < 1_000_000_000
            && self.mode <= 0o7777
            && self.sha256.len() == 64
            && self
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    }

    pub(crate) fn to_value(&self) -> Value {
        json!({
            "schema": self.schema,
            "state": "present",
            "kind": match self.kind { RevisionKind::File => "file" },
            "dev": self.dev,
            "ino": self.ino,
            "size": self.size,
            "mtime_sec": self.mtime_sec,
            "mtime_nsec": self.mtime_nsec,
            "ctime_sec": self.ctime_sec,
            "ctime_nsec": self.ctime_nsec,
            "mode": self.mode,
            "sha256": self.sha256,
        })
    }

    pub(crate) fn from_value(value: &Value) -> Result<Self, String> {
        let object = value
            .as_object()
            .ok_or_else(|| "expected an object".to_string())?;
        let unsigned = |name: &str| {
            object
                .get(name)
                .and_then(Value::as_u64)
                .ok_or_else(|| format!("missing or invalid {name}"))
        };
        let signed = |name: &str| {
            object
                .get(name)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("missing or invalid {name}"))
        };
        let text = |name: &str| {
            object
                .get(name)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("missing or invalid {name}"))
        };
        let state = match text("state")?.as_str() {
            "present" => RevisionState::Present,
            _ => return Err("invalid state (expected present)".into()),
        };
        let kind = match text("kind")?.as_str() {
            "file" => RevisionKind::File,
            _ => return Err("invalid kind".into()),
        };
        let revision = Self {
            schema: u8::try_from(unsigned("schema")?).map_err(|_| "invalid schema")?,
            state,
            kind,
            dev: unsigned("dev")?,
            ino: unsigned("ino")?,
            size: unsigned("size")?,
            mtime_sec: signed("mtime_sec")?,
            mtime_nsec: signed("mtime_nsec")?,
            ctime_sec: signed("ctime_sec")?,
            ctime_nsec: signed("ctime_nsec")?,
            mode: u32::try_from(unsigned("mode")?).map_err(|_| "invalid mode")?,
            sha256: text("sha256")?,
        };
        if revision.is_valid_file_revision() {
            Ok(revision)
        } else {
            Err("invalid revision schema, metadata, or sha256".into())
        }
    }
}

impl ConflictKind {
    pub(super) fn wire_name(&self) -> &'static str {
        match self {
            Self::Changed => "changed",
            Self::Deleted => "deleted",
            Self::Appeared => "appeared",
            Self::TypeChanged => "type_changed",
        }
    }

    pub(super) fn readable_name(&self) -> &'static str {
        match self {
            Self::Changed => "remote file changed",
            Self::Deleted => "remote file was deleted",
            Self::Appeared => "remote file appeared",
            Self::TypeChanged => "remote file type changed",
        }
    }
}

impl RevisionError {
    pub(crate) fn readable(&self) -> String {
        match self {
            Self::Conflict { kind, .. } => format!("write conflict: {}", kind.readable_name()),
            Self::UnstableRead => "read: file changed while being read".into(),
            Self::UnsupportedFinalType(kind) => {
                format!("read: unsupported final file type: {kind}")
            }
            Self::UnsupportedEncoding => "read/write: file is not valid UTF-8".into(),
            Self::TooLarge => format!("read: file exceeds {}-byte limit", super::MAX_READ_BYTES),
            Self::Io(message) => message.clone(),
        }
    }
}

/// SHA-256 hash implementation.
pub(super) fn sha256(bytes: &[u8]) -> String {
    const INITIAL: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let bit_len = (bytes.len() as u64).wrapping_mul(8);
    let mut padded = Vec::with_capacity(bytes.len() + 72);
    padded.extend_from_slice(bytes);
    padded.push(0x80);
    while (padded.len() + 8) % 64 != 0 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());
    let mut hash = INITIAL;
    for chunk in padded.chunks_exact(64) {
        let mut words = [0u32; 64];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            *word = u32::from_be_bytes(chunk[index * 4..index * 4 + 4].try_into().unwrap());
        }
        for index in 16..64 {
            let s0 = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let s1 = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = hash;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choose = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(choose)
                .wrapping_add(K[index])
                .wrapping_add(words[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        hash[0] = hash[0].wrapping_add(a);
        hash[1] = hash[1].wrapping_add(b);
        hash[2] = hash[2].wrapping_add(c);
        hash[3] = hash[3].wrapping_add(d);
        hash[4] = hash[4].wrapping_add(e);
        hash[5] = hash[5].wrapping_add(f);
        hash[6] = hash[6].wrapping_add(g);
        hash[7] = hash[7].wrapping_add(h);
    }
    hash.iter().map(|word| format!("{word:08x}")).collect()
}

pub(crate) fn io_error(context: &str, error: std::io::Error) -> RevisionError {
    RevisionError::Io(format!("{context}: {error}"))
}

pub(crate) fn final_type(metadata: &fs::Metadata) -> Option<&'static str> {
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        Some("symlink")
    } else if file_type.is_dir() {
        Some("directory")
    } else if file_type.is_fifo() {
        Some("fifo")
    } else if !file_type.is_file() {
        Some("nonregular")
    } else if metadata.nlink() != 1 {
        Some("hardlink")
    } else {
        None
    }
}

pub(crate) fn checked_lstat(path: &Path) -> Result<Option<fs::Metadata>, RevisionError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error("read", error)),
    }
}

pub(crate) fn open_checked(path: &Path) -> Result<std::fs::File, RevisionError> {
    let initial =
        checked_lstat(path)?.ok_or_else(|| RevisionError::Io("read: file not found".into()))?;
    if let Some(kind) = final_type(&initial) {
        return Err(RevisionError::UnsupportedFinalType(kind));
    }
    std::fs::OpenOptions::new()
        .read(true)
        // O_NOFOLLOW closes the lstat/open race for final symlinks.  O_NONBLOCK
        // keeps a malicious replacement FIFO from stalling a server worker.
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| io_error("read", error))
}

pub(crate) fn metadata_equal(before: &fs::Metadata, after: &fs::Metadata) -> bool {
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.size() == after.size()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
        && before.mode() == after.mode()
        && before.uid() == after.uid()
        && before.gid() == after.gid()
        && before.nlink() == after.nlink()
}

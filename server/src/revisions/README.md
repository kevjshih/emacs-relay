# Revisions Module

Server-side revision tokens for optimistic-concurrency conditional writes. The `Revision` struct is a schema + state + hash identity token for a file, checked before a write is allowed to proceed so that a stale client never silently overwrites a change it didn't see.

## Module Structure

- **`types.rs`**: Core types (`Revision`, `RevisionError`, `ConflictKind`, etc.) and shared helpers (`sha256`, `final_type`, `checked_lstat`, etc.) used by both read and write paths.
- **`read.rs`**: Read path — establishes stable file descriptors via retry logic (`read_with_revision`, `read_with_revision_hook`).
- **`write.rs`**: Write path — conditional writes with conflict detection (`conditional_write_locked`, `conflict_for_existing`, etc.). Depends on the read path to verify file state after publication.
- **`tests.rs`**: Test module verifying read stability, write atomicity, conflict detection, and edge cases across both paths.

## Entry Points

Start with `Revision` in `types.rs` for the token schema. `RevisionError` and `ConflictKind` describe failure modes. `read_with_revision` and `conditional_write` (in `mod.rs`) are the public API.

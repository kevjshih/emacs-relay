//! Relay server (Milestone 0).
//!
//! Copyright (C) 2026 Kevin Shih
//!
//! This program is free software: you can redistribute it and/or modify
//! it under the terms of the GNU General Public License as published by
//! the Free Software Foundation, either version 3 of the License, or
//! (at your option) any later version.
//!
//! This program is distributed in the hope that it will be useful,
//! but WITHOUT ANY WARRANTY; without even the implied warranty of
//! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//! GNU General Public License for more details.
//!
//! You should have received a copy of the GNU General Public License
//! along with this program. If not, see <https://www.gnu.org/licenses/>.
//!
//! Speaks a framed JSON protocol over stdin/stdout. The local Emacs side launches
//! this over `ssh DEST relay-server` (so ~/.ssh/config governs the connection).
//!
//! Framing: 4-byte little-endian length prefix + UTF-8 JSON payload, both ways.
//! File bytes are base64 (`read`/`write`). See docs/M0-async-file-layer.md.
//!
//! A single writer thread owns stdout and drains an mpsc channel, so request
//! replies and asynchronous FS-watch events never corrupt each other's frames.

mod revisions;
mod framing;
mod control;
mod fs_handlers;

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Mutex};
use std::thread;
use notify::EventKind;
use serde_json::{json, Value};

use control::handle_ctl;
use fs_handlers::{handle_fs, kill_registered_execs, new_exec_registry};
use framing::frame_size_allowed;

const WRITER_QUEUE_CAPACITY: usize = 64;
const FS_WORKER_COUNT: usize = 8;
const FS_JOB_QUEUE_CAPACITY: usize = 64;

fn main() {
    let (tx, rx) = sync_channel::<Vec<u8>>(WRITER_QUEUE_CAPACITY);

    // Single writer thread: framed length-prefixed messages to stdout.
    let _writer = thread::spawn(move || {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        for payload in rx {
            let len = (payload.len() as u32).to_le_bytes();
            if out.write_all(&len).is_err() || out.write_all(&payload).is_err() || out.flush().is_err()
            {
                break;
            }
        }
    });

    // A fixed-size pool bounds both concurrent filesystem work and queued
    // request memory.  Receiving under the mutex only serializes dequeueing;
    // each worker releases it before doing filesystem I/O.
    let (fs_tx, fs_rx) = sync_channel::<Value>(FS_JOB_QUEUE_CAPACITY);
    let fs_rx = Arc::new(Mutex::new(fs_rx));
    let exec_registry = new_exec_registry();
    let mut _workers = Vec::with_capacity(FS_WORKER_COUNT);
    for _ in 0..FS_WORKER_COUNT {
        let fs_rx = Arc::clone(&fs_rx);
        let tx = tx.clone();
        let exec_registry = Arc::clone(&exec_registry);
        _workers.push(thread::spawn(move || loop {
            let req = match fs_rx.lock().unwrap().recv() {
                Ok(req) => req,
                Err(_) => break,
            };
            handle_fs(&req, &tx, &exec_registry);
        }));
    }

    // canonical watched dir -> requested alias(es) for that dir. On macOS (and
    // anywhere a watched ancestor is a symlink, e.g. /tmp -> /private/tmp),
    // FSEvents reports paths in canonical form regardless of what string was
    // passed to watch() — so an event's dir can differ from the exact path
    // Emacs cached under. We register the *canonical* path with the watcher
    // and translate events back to every alias Emacs actually asked about, so
    // its cache invalidation always finds the key it's holding.
    let watched: Arc<Mutex<HashMap<String, Vec<String>>>> = Arc::new(Mutex::new(HashMap::new()));
    let watched_for_events = Arc::clone(&watched);

    // One FS watcher; events and overflow -> writer channel (id = 0, no id field).
    let event_tx = tx.clone();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
        Ok(event) => {
            let kind = match event.kind {
                EventKind::Create(_) => "created",
                EventKind::Remove(_) => "removed",
                EventKind::Modify(_) => "modified",
                _ => "modified",
            };
            for p in event.paths {
                let p_str = p.to_string_lossy().to_string();
                // Self-referential case first: the changed PATH ITSELF is
                // something we watch directly (not just a child inside some
                // watched parent) — e.g. this directory being renamed or
                // deleted out from under us. A watch is only ever
                // registered on the exact path asked for, so if THAT path
                // is what changed, report it using its own alias(es)
                // directly, with a distinct event kind, rather than folding
                // it into the ordinary "child NAME changed inside DIR"
                // shape below. That ordinary shape can't represent this
                // case correctly: the parent here may not have any
                // registered alias at all (we may never have watched it),
                // so a client that only ever invalidates by that shape's
                // `dir' has nothing to invalidate the watched target's own
                // entry with. Confirmed empirically: renaming a directly-
                // watched directory reports a plain created/modified event
                // against its parent's canonical path, not a "removed"
                // event scoped to the directory itself.
                let self_aliases = watched_for_events.lock().unwrap().get(&p_str).cloned();
                if let Some(aliases) = self_aliases {
                    for alias in aliases {
                        let _ = event_tx.send(
                            json!({"event": "self_changed", "dir": alias}).to_string().into_bytes(),
                        );
                    }
                    continue;
                }
                let dir_canon = p
                    .parent()
                    .map(|d| d.to_string_lossy().to_string())
                    .unwrap_or_default();
                let name = p
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();
                let dirs = {
                    let map = watched_for_events.lock().unwrap();
                    map.get(&dir_canon).cloned()
                }
                .unwrap_or_else(|| vec![dir_canon.clone()]);
                for dir in dirs {
                    let _ = event_tx.send(
                        json!({"event": kind, "dir": dir, "name": name}).to_string().into_bytes(),
                    );
                }
            }
        }
        // Watch error / queue overflow: coarse invalidation signal.
        Err(_) => {
            let _ = event_tx.send(json!({"event": "overflow"}).to_string().into_bytes());
        }
    });
    let mut watcher = watcher.ok();

    // Main loop: read framed requests from stdin.
    let mut stdin = io::stdin().lock();
    loop {
        let mut lenbuf = [0u8; 4];
        if stdin.read_exact(&mut lenbuf).is_err() {
            break; // EOF -> connection closed
        }
        let n = u32::from_le_bytes(lenbuf) as usize;
        if !frame_size_allowed(n) {
            // Never allocate attacker-controlled frame sizes.  Close this
            // connection rather than trying to resynchronize an invalid stream.
            break;
        }
        let mut buf = vec![0u8; n];
        if stdin.read_exact(&mut buf).is_err() {
            break;
        }
        let req: Value = match serde_json::from_slice(&buf) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match req.get("op").and_then(Value::as_str).unwrap_or("") {
            // Control ops need the watcher and are fast: handle inline.
            "hello" | "watch" | "unwatch" => handle_ctl(&req, &tx, &mut watcher, &watched),
            // FS ops run in the bounded worker pool below so slow reads do not
            // head-of-line-block metadata ops, without allowing a client to
            // create an unbounded number of OS threads.
            _ => {
                if fs_tx.send(req).is_err() {
                    break;
                }
            }
        }
    }

    // EOF means the sole client is gone, so queued replies are no longer
    // observable.  Do not join filesystem workers here: a syscall blocked on
    // a FIFO or an unavailable mount could otherwise orphan this per-connection
    // server indefinitely.  Dropping JoinHandles detaches the threads; return
    // from main terminates the process and lets the OS release all resources.
    kill_registered_execs(&exec_registry);
}

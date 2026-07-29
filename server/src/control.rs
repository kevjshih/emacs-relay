/// Control operations: watch/unwatch and hello.
///
/// These are fast and require the FS watcher, so they run on the main thread.

use crate::framing::{expand_home, finish};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::mpsc::SyncSender;
use std::sync::{Arc, Mutex};
use notify::{RecursiveMode, Watcher};

const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
const PROTOCOL_VERSION: u32 = 1;

/// Control ops: need the watcher, and are fast. Runs on the main thread.
pub(crate) fn handle_ctl(
    req: &Value,
    tx: &SyncSender<Vec<u8>>,
    watcher: &mut Option<notify::RecommendedWatcher>,
    watched: &Arc<Mutex<HashMap<String, Vec<String>>>>,
) {
    let id = req.get("id").and_then(Value::as_i64).unwrap_or(0);
    let op = req.get("op").and_then(Value::as_str).unwrap_or("");
    let path = req.get("path").and_then(Value::as_str).unwrap_or("");
    let result: Result<Value, String> = match op {
        "hello" => Ok(json!({
            "server_version": SERVER_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "capabilities": ["revisions-v1", "exec-v1"],
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        })),
        "watch" => {
            // Canonicalize so the underlying watch always keys on the same
            // real directory notify will report back, no matter which alias
            // (symlinked or not) the caller asked about.
            let expanded_path = expand_home(path);
            let canon = fs::canonicalize(&expanded_path)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or(expanded_path);
            let mut map = watched.lock().unwrap();
            let already_watching = map.contains_key(&canon);
            let aliases = map.entry(canon.clone()).or_default();
            if !aliases.iter().any(|a| a == path) {
                aliases.push(path.to_string());
            }
            drop(map);
            if already_watching {
                Ok(json!({}))
            } else {
                match watcher {
                    Some(w) => match w.watch(Path::new(&canon), RecursiveMode::NonRecursive) {
                        Ok(_) => Ok(json!({})),
                        Err(e) => {
                            watched.lock().unwrap().remove(&canon);
                            Err(format!("watch: {e}"))
                        }
                    },
                    None => Err("no watcher available".into()),
                }
            }
        }
        "unwatch" => {
            let mut map = watched.lock().unwrap();
            let mut emptied_canon = None;
            for (canon, aliases) in map.iter_mut() {
                if let Some(pos) = aliases.iter().position(|a| a == path) {
                    aliases.remove(pos);
                    if aliases.is_empty() {
                        emptied_canon = Some(canon.clone());
                    }
                    break;
                }
            }
            if let Some(canon) = emptied_canon {
                map.remove(&canon);
                drop(map);
                if let Some(w) = watcher {
                    let _ = w.unwatch(Path::new(&canon));
                }
            }
            Ok(json!({}))
        }
        other => Err(format!("unknown ctl op: {other}")),
    };
    finish(tx, id, result);
}

//! The file bridge between the companion and the game.
//!
//! The game's scripting runtime cannot open sockets, but it can read and
//! write files in its save directory. Both sides exchange numbered JSON
//! batches there (see `MtIpc.gml` for the game half):
//!
//! ```text
//! game.json                  game heartbeat + identity     (game writes)
//! link.json                  companion heartbeat + status  (companion writes)
//! g_<sid>_<epoch>_<n>.json   batch, game -> companion
//! l_<epoch>_<sid>_<n>.json   batch, companion -> game
//! ```
//!
//! Every file is written under a temporary name and renamed into place, and
//! batches are consumed strictly in order, so nothing is torn, lost or
//! reordered. Runs on its own thread with plain blocking IO.

use crate::log;
use crate::proto::{TO_ALL, TO_HOST};
use serde::Deserialize;
use serde_json::value::RawValue;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc::UnboundedSender;

/// What the bridge knows about the running game.
#[derive(Debug, Clone, PartialEq)]
pub struct GameInfo {
    pub dir: PathBuf,
    pub sid: String,
    /// A save is loaded and the player is in the world.
    pub ready: bool,
    pub name: String,
    pub proto: u32,
    pub mod_version: String,
}

#[derive(Debug)]
pub enum OutMsg {
    /// A message for other players. `to` is a wire address.
    Peer { to: u8, unreliable: bool, json: String },
    /// A request to the companion itself (file transfers).
    Link(serde_json::Value),
}

#[derive(Debug)]
pub enum ToNet {
    /// The paired game changed (started, loaded a save, went away).
    Game(Option<GameInfo>),
    Out(OutMsg),
}

#[derive(Debug)]
pub enum ToGame {
    /// `from` is a peer id, or -1 for messages produced by the companion.
    Msg { from: i32, unreliable: bool, json: String },
    Status { state: String, detail: String },
}

#[derive(Deserialize)]
struct GameFile {
    #[serde(default)]
    proto: u32,
    #[serde(default)]
    ver: String,
    sid: String,
    #[serde(default)]
    hb: f64,
    #[serde(default)]
    ready: bool,
    #[serde(default)]
    name: String,
}

#[derive(Deserialize)]
struct OutBatch<'a> {
    #[serde(borrow)]
    m: Vec<OutEntry<'a>>,
}

#[derive(Deserialize)]
struct OutEntry<'a> {
    to: i64,
    #[serde(default)]
    u: u8,
    #[serde(borrow)]
    d: &'a RawValue,
}

const GAME_TIMEOUT: Duration = Duration::from_secs(8);
const SCAN_INTERVAL: Duration = Duration::from_millis(100);
const LINK_INTERVAL: Duration = Duration::from_millis(250);
const FLUSH_INTERVAL: Duration = Duration::from_millis(8);
const LOOP_SLEEP: Duration = Duration::from_millis(3);
/// Unread batches the game may have before we start holding messages back.
const MAX_BACKLOG: u64 = 40;

struct Candidate {
    dir: PathBuf,
    last_hb: f64,
    last_sid: String,
    last_change: Option<Instant>,
    seen: bool,
    info: Option<GameInfo>,
}

struct Paired {
    info: GameInfo,
    out_seq: u64,     // next g_ batch to read
    in_seq: u64,      // next l_ batch to write
    in_oldest: u64,   // oldest l_ batch the game may not have read yet
}

pub struct Bridge {
    candidates: Vec<Candidate>,
    epoch: String,
    hb: u64,
    paired: Option<Paired>,
    pending: Vec<(i32, bool, String)>,
    state: String,
    detail: String,
    to_net: UnboundedSender<ToNet>,
    from_net: Receiver<ToGame>,
    stop: Arc<AtomicBool>,
}

fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = dir.join("link.tmp");
    fs::write(&tmp, bytes)?;
    let dest = dir.join(name);
    match fs::rename(&tmp, &dest) {
        Ok(()) => Ok(()),
        Err(_) => {
            // Windows refuses to replace a file another process has open;
            // the reader is done within microseconds, so retry briefly.
            for _ in 0..20 {
                std::thread::sleep(Duration::from_millis(2));
                if fs::rename(&tmp, &dest).is_ok() {
                    return Ok(());
                }
            }
            fs::rename(&tmp, &dest)
        }
    }
}

fn read_with_retry(path: &Path) -> Option<Vec<u8>> {
    for _ in 0..10 {
        match fs::read(path) {
            Ok(b) => return Some(b),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            Err(_) => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    None
}

pub fn new_epoch() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut h = RandomState::new().build_hasher();
    h.write_u32(std::process::id());
    format!("{:010x}", h.finish() & 0xff_ffff_ffff)
}

impl Bridge {
    /// `ipc_dirs` are the places a game might be exchanging files in (one per
    /// save-data location that exists on this machine).
    pub fn new(
        ipc_dirs: Vec<PathBuf>,
        to_net: UnboundedSender<ToNet>,
        from_net: Receiver<ToGame>,
        stop: Arc<AtomicBool>,
    ) -> Bridge {
        Bridge {
            candidates: ipc_dirs
                .into_iter()
                .map(|dir| Candidate { dir, last_hb: -1.0, last_sid: String::new(), last_change: None, seen: false, info: None })
                .collect(),
            epoch: new_epoch(),
            hb: 0,
            paired: None,
            pending: Vec::new(),
            state: "idle".into(),
            detail: "starting".into(),
            to_net,
            from_net,
            stop,
        }
    }

    pub fn run(mut self) {
        let mut last_scan = Instant::now() - SCAN_INTERVAL;
        let mut last_link = Instant::now() - LINK_INTERVAL;
        let mut last_flush = Instant::now();
        self.clean_all();
        while !self.stop.load(Ordering::Relaxed) {
            let now = Instant::now();
            if now.duration_since(last_scan) >= SCAN_INTERVAL {
                last_scan = now;
                self.scan();
            }
            self.read_outbound();
            if !self.drain_from_net() {
                break;
            }
            if now.duration_since(last_flush) >= FLUSH_INTERVAL {
                last_flush = now;
                self.flush_inbound();
            }
            if now.duration_since(last_link) >= LINK_INTERVAL {
                last_link = now;
                self.write_link();
            }
            std::thread::sleep(LOOP_SLEEP);
        }
        // Tell the game we are gone instead of letting the heartbeat time out.
        for c in &self.candidates {
            let _ = fs::remove_file(c.dir.join("link.json"));
        }
    }

    /// Remove batches left over from an earlier run.
    fn clean_all(&self) {
        for c in &self.candidates {
            Self::clean_dir(&c.dir);
        }
    }

    fn clean_dir(dir: &Path) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let stale = (name.starts_with("g_") || name.starts_with("l_")) && name.ends_with(".json")
                || name.starts_with("blob_in_")
                || name.starts_with("blob_out_")
                || name == "link.tmp";
            if stale {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    fn scan(&mut self) {
        let now = Instant::now();
        for c in &mut self.candidates {
            let parsed = read_with_retry(&c.dir.join("game.json")).and_then(|b| serde_json::from_slice::<GameFile>(&b).ok());
            let Some(g) = parsed else {
                continue;
            };
            if g.hb != c.last_hb || g.sid != c.last_sid {
                // The first sighting of an old file is not proof of life: the
                // heartbeat has to move while we watch.
                if c.seen {
                    c.last_change = Some(now);
                }
                c.last_hb = g.hb;
                c.last_sid = g.sid.clone();
            }
            c.seen = true;
            let alive = c.last_change.map(|t| now.duration_since(t) < GAME_TIMEOUT).unwrap_or(false);
            c.info = alive.then(|| GameInfo {
                dir: c.dir.clone(),
                sid: g.sid,
                ready: g.ready,
                name: g.name,
                proto: g.proto,
                mod_version: g.ver,
            });
        }

        let current = self.paired.as_ref().map(|p| p.info.dir.clone());
        let chosen = self
            .candidates
            .iter()
            .filter(|c| c.info.is_some())
            .max_by_key(|c| (Some(&c.dir) == current.as_ref(), c.last_change))
            .and_then(|c| c.info.clone());

        match (&mut self.paired, chosen) {
            (Some(p), Some(info)) if p.info.dir == info.dir && p.info.sid == info.sid => {
                if p.info != info {
                    p.info = info.clone();
                    let _ = self.to_net.send(ToNet::Game(Some(info)));
                }
            }
            (_, Some(info)) => {
                log!("game found ({}) in {}", if info.name.is_empty() { "on the title screen" } else { &info.name }, info.dir.display());
                Self::clean_dir(&info.dir);
                self.pending.clear();
                self.paired = Some(Paired { info: info.clone(), out_seq: 0, in_seq: 0, in_oldest: 0 });
                let _ = self.to_net.send(ToNet::Game(Some(info)));
            }
            (Some(_), None) => {
                log!("game went away");
                self.paired = None;
                self.pending.clear();
                let _ = self.to_net.send(ToNet::Game(None));
            }
            (None, None) => {}
        }
    }

    fn read_outbound(&mut self) {
        let Some(p) = &mut self.paired else { return };
        for _ in 0..32 {
            let path = p.info.dir.join(format!("g_{}_{}_{}.json", p.info.sid, self.epoch, p.out_seq));
            let Some(bytes) = read_with_retry(&path) else { break };
            let _ = fs::remove_file(&path);
            p.out_seq += 1;
            let batch: OutBatch = match serde_json::from_slice(&bytes) {
                Ok(b) => b,
                Err(e) => {
                    log!("ignoring unreadable batch from the game: {e}");
                    continue;
                }
            };
            for entry in batch.m {
                let msg = match entry.to {
                    -1 => OutMsg::Peer { to: TO_ALL, unreliable: entry.u == 1, json: entry.d.get().to_owned() },
                    -2 => OutMsg::Peer { to: TO_HOST, unreliable: entry.u == 1, json: entry.d.get().to_owned() },
                    -3 => match serde_json::from_str(entry.d.get()) {
                        Ok(v) => OutMsg::Link(v),
                        Err(_) => continue,
                    },
                    id @ 1..=253 => OutMsg::Peer { to: id as u8, unreliable: entry.u == 1, json: entry.d.get().to_owned() },
                    _ => continue,
                };
                let _ = self.to_net.send(ToNet::Out(msg));
            }
        }
    }

    /// Returns false when the network side is gone and the bridge should stop.
    fn drain_from_net(&mut self) -> bool {
        loop {
            match self.from_net.try_recv() {
                Ok(ToGame::Msg { from, unreliable, json }) => {
                    if self.paired.is_some() {
                        self.pending.push((from, unreliable, json));
                    }
                }
                Ok(ToGame::Status { state, detail }) => {
                    if self.state != state || self.detail != detail {
                        log!("{state}: {detail}");
                    }
                    self.state = state;
                    self.detail = detail;
                }
                Err(TryRecvError::Empty) => return true,
                Err(TryRecvError::Disconnected) => return false,
            }
        }
    }

    fn flush_inbound(&mut self) {
        let Some(p) = &mut self.paired else { return };
        if self.pending.is_empty() {
            return;
        }
        let name = |seq: u64| format!("l_{}_{}_{}.json", self.epoch, p.info.sid, seq);
        while p.in_oldest < p.in_seq && !p.info.dir.join(name(p.in_oldest)).exists() {
            p.in_oldest += 1;
        }
        if p.in_seq - p.in_oldest >= MAX_BACKLOG {
            // The game is not reading (loading screen, hitch). Keep reliable
            // messages, and only the newest unreliable one per sender.
            let mut seen = std::collections::HashSet::new();
            let mut kept: Vec<(i32, bool, String)> = Vec::with_capacity(self.pending.len());
            for msg in self.pending.drain(..).rev() {
                if !msg.1 || seen.insert(msg.0) {
                    kept.push(msg);
                }
            }
            kept.reverse();
            self.pending = kept;
            return;
        }
        let mut text = String::with_capacity(64 + self.pending.iter().map(|m| m.2.len() + 16).sum::<usize>());
        text.push_str("{\"m\":[");
        for (i, (from, _, json)) in self.pending.iter().enumerate() {
            if i > 0 {
                text.push(',');
            }
            text.push_str("{\"f\":");
            text.push_str(&from.to_string());
            text.push_str(",\"d\":");
            text.push_str(json);
            text.push('}');
        }
        text.push_str("]}");
        match write_atomic(&p.info.dir, &name(p.in_seq), text.as_bytes()) {
            Ok(()) => {
                p.in_seq += 1;
                self.pending.clear();
            }
            Err(e) => log!("could not write to {}: {e}", p.info.dir.display()),
        }
    }

    fn write_link(&mut self) {
        self.hb += 1;
        let body = serde_json::json!({
            "epoch": self.epoch,
            "hb": self.hb,
            "state": self.state,
            "detail": self.detail,
        })
        .to_string();
        for c in &self.candidates {
            // Only where the mod has been (or the game data dir exists): never
            // create save directories for a game that is not installed here.
            if c.dir.exists() || c.dir.parent().and_then(|p| p.parent()).and_then(|p| p.parent()).map(|p| p.exists()).unwrap_or(false) {
                if fs::create_dir_all(&c.dir).is_ok() {
                    let _ = write_atomic(&c.dir, "link.json", body.as_bytes());
                }
            }
        }
    }
}

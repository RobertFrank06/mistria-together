//! File transfers between games (world snapshots are megabytes of JSON, far
//! too big for the message path).
//!
//! The sending game writes `blob_out_*` into its ipc directory and asks its
//! companion to ship it. The data is deflated, cut into chunks that interleave
//! with normal traffic, reassembled on the other side and written to that
//! game's ipc directory as `blob_in_<n>.dat`. File names never cross the
//! network: the receiver picks its own.

use crate::proto::{Frame, RelayKind, TO_ALL, TO_HOST};
use anyhow::{anyhow, bail, Result};
use flate2::read::{DeflateDecoder, DeflateEncoder};
use flate2::Compression;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use tokio::sync::mpsc::Sender;

const CHUNK: usize = 60 * 1024;
const MAX_COMPRESSED: usize = 64 * 1024 * 1024;
const MAX_RAW: u64 = 256 * 1024 * 1024;
const MAX_CHUNKS: u32 = (MAX_COMPRESSED / CHUNK) as u32 + 2;

#[derive(Serialize, Deserialize)]
struct Header {
    kind: String,
    #[serde(default)]
    meta: serde_json::Value,
    raw_len: u64,
}

fn valid_kind(kind: &str) -> bool {
    !kind.is_empty() && kind.len() <= 24 && kind.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

/// Handle `{t:"blob", to, kind, file, meta}` from the game.
pub async fn send(dir: &Path, req: &serde_json::Value, blob_id: u32, tx: Sender<Vec<u8>>) -> Result<()> {
    let file = req.get("file").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("blob request without a file"))?;
    // The game only ever names files it just wrote next to its batches.
    if !file.starts_with("blob_out_") || file.contains(['/', '\\']) || file.contains("..") {
        bail!("refusing to send {file:?}");
    }
    let kind = req.get("kind").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if !valid_kind(&kind) {
        bail!("bad blob kind {kind:?}");
    }
    let to = match req.get("to").and_then(|v| v.as_i64()).unwrap_or(-1) {
        -1 => TO_ALL,
        -2 => TO_HOST,
        id @ 1..=253 => id as u8,
        other => bail!("bad blob destination {other}"),
    };
    let meta = req.get("meta").cloned().unwrap_or(serde_json::Value::Null);
    let path = dir.join(file);

    let packed = tokio::task::spawn_blocking(move || -> Result<Vec<u8>> {
        let raw = std::fs::read(&path).map_err(|e| anyhow!("cannot read {}: {e}", path.display()))?;
        let _ = std::fs::remove_file(&path);
        let header = serde_json::to_vec(&Header { kind, meta, raw_len: raw.len() as u64 })?;
        let mut out = Vec::with_capacity(raw.len() / 6 + header.len() + 16);
        out.extend_from_slice(&(header.len() as u32).to_be_bytes());
        out.extend_from_slice(&header);
        DeflateEncoder::new(&raw[..], Compression::fast()).read_to_end(&mut out)?;
        Ok(out)
    })
    .await??;
    if packed.len() > MAX_COMPRESSED {
        bail!("file too large to send ({} MB)", packed.len() / 1_048_576);
    }

    let total = packed.len().div_ceil(CHUNK).max(1) as u32;
    for (idx, chunk) in packed.chunks(CHUNK).enumerate() {
        let mut payload = Vec::with_capacity(12 + chunk.len());
        payload.extend_from_slice(&blob_id.to_be_bytes());
        payload.extend_from_slice(&(idx as u32).to_be_bytes());
        payload.extend_from_slice(&total.to_be_bytes());
        payload.extend_from_slice(chunk);
        let frame = Frame::Relay { peer: to, kind: RelayKind::Blob, payload }.encode();
        tx.send(frame).await.map_err(|_| anyhow!("connection closed"))?;
    }
    Ok(())
}

pub struct Finished {
    pub kind: String,
    pub file: String,
    pub meta: serde_json::Value,
}

struct Partial {
    total: u32,
    next: u32,
    data: Vec<u8>,
}

pub struct Assembler {
    dir: PathBuf,
    partial: HashMap<(u8, u32), Partial>,
    counter: u32,
    written: Vec<PathBuf>,
}

impl Assembler {
    pub fn new(dir: PathBuf) -> Self {
        Assembler { dir, partial: HashMap::new(), counter: 0, written: Vec::new() }
    }

    /// Feed one chunk. Chunks of a blob arrive in order (they travel on TCP).
    pub fn push(&mut self, from: u8, payload: &[u8]) -> Result<Option<Finished>> {
        if payload.len() < 12 {
            bail!("short chunk");
        }
        let id = u32::from_be_bytes(payload[0..4].try_into().unwrap());
        let idx = u32::from_be_bytes(payload[4..8].try_into().unwrap());
        let total = u32::from_be_bytes(payload[8..12].try_into().unwrap());
        let chunk = &payload[12..];
        if total == 0 || total > MAX_CHUNKS {
            bail!("bad chunk count {total}");
        }
        let key = (from, id);
        if idx == 0 {
            self.partial.insert(key, Partial { total, next: 0, data: Vec::new() });
        }
        let part = self.partial.get_mut(&key).ok_or_else(|| anyhow!("chunk for an unknown transfer"))?;
        if idx != part.next || total != part.total || part.data.len() + chunk.len() > MAX_COMPRESSED {
            self.partial.remove(&key);
            bail!("transfer out of sequence");
        }
        part.data.extend_from_slice(chunk);
        part.next += 1;
        if part.next < part.total {
            return Ok(None);
        }
        let part = self.partial.remove(&key).unwrap();
        let data = part.data;
        if data.len() < 4 {
            bail!("empty transfer");
        }
        let header_len = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
        if header_len > 1_048_576 || data.len() < 4 + header_len {
            bail!("bad transfer header");
        }
        let header: Header = serde_json::from_slice(&data[4..4 + header_len])?;
        if !valid_kind(&header.kind) || header.raw_len > MAX_RAW {
            bail!("bad transfer header");
        }
        let mut raw = Vec::with_capacity(header.raw_len as usize);
        DeflateDecoder::new(&data[4 + header_len..]).take(header.raw_len + 1).read_to_end(&mut raw)?;
        if raw.len() as u64 != header.raw_len {
            bail!("transfer has the wrong length");
        }
        self.counter += 1;
        let file = format!("blob_in_{}_{}.dat", from, self.counter);
        let tmp = self.dir.join("blob.tmp");
        std::fs::write(&tmp, &raw)?;
        let dest = self.dir.join(&file);
        std::fs::rename(&tmp, &dest)?;
        self.written.push(dest);
        Ok(Some(Finished { kind: header.kind, file, meta: header.meta }))
    }

    pub fn forget(&mut self, from: u8) {
        self.partial.retain(|(f, _), _| *f != from);
    }

    /// Remove received files the game never picked up.
    pub fn cleanup(&mut self) {
        for path in self.written.drain(..) {
            let _ = std::fs::remove_file(path);
        }
    }
}

//! End-to-end tests of the companion: real hub, real sockets, real files.
//! `FakeGame` plays the part of the mod, speaking the same file protocol as
//! `MtIpc.gml`.

use mistria_together::{Companion, Mode, Options};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct FakeGame {
    dir: PathBuf,
    sid: String,
    name: String,
    hb: u64,
    epoch: String,
    in_seq: u64,
    out_seq: u64,
    ready: bool,
    inbox: Vec<(i64, Value)>,
}

impl FakeGame {
    fn new(dir: PathBuf, name: &str) -> FakeGame {
        std::fs::create_dir_all(&dir).unwrap();
        let sid = format!("{}{}", name.to_lowercase(), std::process::id());
        FakeGame { dir, sid, name: name.into(), hb: 0, epoch: String::new(), in_seq: 0, out_seq: 0, ready: true, inbox: vec![] }
    }

    fn write(&self, name: &str, text: &str) {
        let tmp = self.dir.join("game.tmp");
        std::fs::write(&tmp, text).unwrap();
        std::fs::rename(tmp, self.dir.join(name)).unwrap();
    }

    /// One "frame": heartbeat, pairing, read inbound batches.
    fn pump(&mut self) {
        self.hb += 1;
        let game = json!({ "proto": 1, "ver": "test", "sid": self.sid, "hb": self.hb, "ready": self.ready, "name": self.name, "farm": "F" });
        self.write("game.json", &game.to_string());
        if let Ok(bytes) = std::fs::read(self.dir.join("link.json")) {
            if let Ok(link) = serde_json::from_slice::<Value>(&bytes) {
                let epoch = link["epoch"].as_str().unwrap_or("").to_string();
                if epoch != self.epoch {
                    self.epoch = epoch;
                    self.in_seq = 0;
                    self.out_seq = 0;
                }
            }
        }
        loop {
            let path = self.dir.join(format!("l_{}_{}_{}.json", self.epoch, self.sid, self.in_seq));
            let Ok(bytes) = std::fs::read(&path) else { break };
            std::fs::remove_file(&path).unwrap();
            self.in_seq += 1;
            let batch: Value = serde_json::from_slice(&bytes).expect("batch is valid json");
            for m in batch["m"].as_array().unwrap() {
                self.inbox.push((m["f"].as_i64().unwrap(), m["d"].clone()));
            }
        }
    }

    fn send(&mut self, to: i64, unreliable: bool, data: Value) {
        assert!(!self.epoch.is_empty(), "not paired yet");
        let batch = json!({ "m": [{ "to": to, "u": if unreliable { 1 } else { 0 }, "d": data }] });
        self.write(&format!("g_{}_{}_{}.json", self.sid, self.epoch, self.out_seq), &batch.to_string());
        self.out_seq += 1;
    }

    fn take(&mut self, t: &str) -> Option<(i64, Value)> {
        let pos = self.inbox.iter().position(|(_, d)| d["t"] == t)?;
        Some(self.inbox.remove(pos))
    }
}

/// Pump all games until `cond` holds.
async fn until(games: &mut [&mut FakeGame], what: &str, mut cond: impl FnMut(&mut [&mut FakeGame]) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        for g in games.iter_mut() {
            g.pump();
        }
        if cond(games) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out waiting for: {what}");
        tokio::time::sleep(Duration::from_millis(16)).await;
    }
}

async fn host(dir: &PathBuf, password: Option<&str>) -> (Companion, String) {
    let c = Companion::start(Options {
        mode: Mode::Host { port: 0, relay: None },
        password: password.map(String::from),
        ipc_dirs: vec![dir.clone()],
    })
    .await
    .unwrap();
    let addr = format!("127.0.0.1:{}", c.hub_addr.unwrap().port());
    (c, addr)
}

async fn join(dir: &PathBuf, addr: &str, password: Option<&str>) -> Companion {
    Companion::start(Options { mode: Mode::Join { addr: addr.into() }, password: password.map(String::from), ipc_dirs: vec![dir.clone()] })
        .await
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn two_players_exchange_messages() {
    let tmp = tempfile::tempdir().unwrap();
    let (hd, gd) = (tmp.path().join("h"), tmp.path().join("g"));
    let mut h = FakeGame::new(hd.clone(), "Host");
    let mut g = FakeGame::new(gd.clone(), "Guest");

    let (_hc, addr) = host(&hd, None).await;
    until(&mut [&mut h], "host welcome", |gs| gs[0].inbox.iter().any(|(_, d)| d["t"] == "welcome")).await;
    let (from, w) = h.take("welcome").unwrap();
    assert_eq!(from, -1);
    assert_eq!(w["id"], w["host"]);
    let host_id = w["id"].as_i64().unwrap();

    let _gc = join(&gd, &addr, None).await;
    until(&mut [&mut h, &mut g], "guest welcome + host sees join", |gs| {
        gs[1].inbox.iter().any(|(_, d)| d["t"] == "welcome") && gs[0].inbox.iter().any(|(_, d)| d["t"] == "join")
    })
    .await;
    let (_, gw) = g.take("welcome").unwrap();
    let guest_id = gw["id"].as_i64().unwrap();
    assert_ne!(guest_id, host_id);
    assert_eq!(gw["host"].as_i64().unwrap(), host_id);
    assert_eq!(gw["peers"][0]["name"], "Host");
    let (_, j) = h.take("join").unwrap();
    assert_eq!(j["name"], "Guest");
    assert_eq!(j["id"].as_i64().unwrap(), guest_id);

    // Reliable, in order, both directions, with awkward content.
    for i in 0..50 {
        h.send(-1, false, json!({ "t": "r", "i": i, "text": "quote \" backslash \\ unicode \u{00e9}\u{1F33E}" }));
        g.send(-2, false, json!({ "t": "q", "i": i }));
    }
    until(&mut [&mut h, &mut g], "100 reliable messages", |gs| {
        gs[0].inbox.iter().filter(|(_, d)| d["t"] == "q").count() == 50 && gs[1].inbox.iter().filter(|(_, d)| d["t"] == "r").count() == 50
    })
    .await;
    for i in 0..50 {
        let (from, d) = g.take("r").unwrap();
        assert_eq!((from, d["i"].as_i64().unwrap()), (host_id, i));
        assert_eq!(d["text"], "quote \" backslash \\ unicode \u{00e9}\u{1F33E}");
        let (from, d) = h.take("q").unwrap();
        assert_eq!((from, d["i"].as_i64().unwrap()), (guest_id, i));
    }

    // Unreliable traffic arrives too on a healthy link (UDP on loopback, or
    // the TCP fallback before the UDP path is confirmed).
    for i in 0..30 {
        g.send(-1, true, json!({ "t": "p", "s": i }));
        h.pump();
        g.pump();
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    until(&mut [&mut h, &mut g], "poses", |gs| gs[0].inbox.iter().filter(|(_, d)| d["t"] == "p").count() >= 25).await;

    // Addressed to one peer.
    h.send(guest_id, false, json!({ "t": "direct" }));
    until(&mut [&mut h, &mut g], "direct message", |gs| gs[1].inbox.iter().any(|(_, d)| d["t"] == "direct")).await;

    // Ping statistics show up.
    until(&mut [&mut h, &mut g], "stats", |gs| gs[1].inbox.iter().any(|(_, d)| d["t"] == "stat")).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn blob_transfer_and_three_players() {
    let tmp = tempfile::tempdir().unwrap();
    let dirs: Vec<PathBuf> = ["h", "a", "b"].iter().map(|n| tmp.path().join(n)).collect();
    let mut h = FakeGame::new(dirs[0].clone(), "Host");
    let mut a = FakeGame::new(dirs[1].clone(), "A");
    let mut b = FakeGame::new(dirs[2].clone(), "B");
    let (_hc, addr) = host(&dirs[0], Some("pw")).await;
    until(&mut [&mut h], "host online", |gs| gs[0].inbox.iter().any(|(_, d)| d["t"] == "welcome")).await;
    let _ac = join(&dirs[1], &addr, Some("pw")).await;
    let _bc = join(&dirs[2], &addr, Some("pw")).await;
    until(&mut [&mut h, &mut a, &mut b], "everyone online", |gs| {
        gs[1].inbox.iter().any(|(_, d)| d["t"] == "welcome") && gs[2].inbox.iter().any(|(_, d)| d["t"] == "welcome")
    })
    .await;
    let a_id = a.take("welcome").unwrap().1["id"].as_i64().unwrap();

    // 3 MB of compressible-but-not-trivial data to one guest only.
    let mut data = Vec::new();
    let mut x: u32 = 12345;
    while data.len() < 3_000_000 {
        x = x.wrapping_mul(1664525).wrapping_add(1013904223);
        data.extend_from_slice(format!("{{\"node\":{},\"v\":{}}},", x % 977, x >> 20).as_bytes());
    }
    std::fs::write(dirs[0].join("blob_out_1_world.json"), &data).unwrap();
    h.send(-3, false, json!({ "t": "blob", "to": a_id, "kind": "world", "file": "blob_out_1_world.json", "meta": { "day": 4 } }));
    // Ordinary traffic keeps flowing while the transfer runs.
    h.send(-1, false, json!({ "t": "during" }));
    until(&mut [&mut h, &mut a, &mut b], "blob arrives", |gs| gs[1].inbox.iter().any(|(_, d)| d["t"] == "blob")).await;
    let (from, blob) = a.take("blob").unwrap();
    assert_eq!(from, -1);
    assert_eq!(blob["kind"], "world");
    assert_eq!(blob["meta"]["day"], 4);
    let got = std::fs::read(dirs[1].join(blob["file"].as_str().unwrap())).unwrap();
    assert!(got == data, "blob content differs");
    assert!(!dirs[0].join("blob_out_1_world.json").exists(), "sent file is consumed");
    assert!(b.take("blob").is_none(), "blob was addressed to A only");
    until(&mut [&mut h, &mut a, &mut b], "broadcast reaches both", |gs| {
        gs[1].inbox.iter().any(|(_, d)| d["t"] == "during") && gs[2].inbox.iter().any(|(_, d)| d["t"] == "during")
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guest_survives_host_leaving_and_wrong_password() {
    let tmp = tempfile::tempdir().unwrap();
    let (hd, gd) = (tmp.path().join("h"), tmp.path().join("g"));
    let mut h = FakeGame::new(hd.clone(), "Host");
    let mut g = FakeGame::new(gd.clone(), "Guest");
    let (_hc, addr) = host(&hd, Some("secret")).await;
    until(&mut [&mut h], "host online", |gs| gs[0].inbox.iter().any(|(_, d)| d["t"] == "welcome")).await;

    // Wrong password: refused with a reason the player can read.
    let bad = join(&gd, &addr, Some("nope")).await;
    until(&mut [&mut h, &mut g], "refusal reaches the game", |gs| {
        std::fs::read_to_string(gs[1].dir.join("link.json")).map(|s| s.contains("wrong password")).unwrap_or(false)
    })
    .await;
    assert!(g.take("welcome").is_none());
    bad.stop();

    let _gc = join(&gd, &addr, Some("secret")).await;
    until(&mut [&mut h, &mut g], "guest online", |gs| gs[1].inbox.iter().any(|(_, d)| d["t"] == "welcome")).await;
    g.inbox.clear();

    // The host goes back to the title screen: the guest is told, then
    // reconnects by itself once the host is back in a save.
    h.ready = false;
    until(&mut [&mut h, &mut g], "guest told the host left", |gs| gs[1].inbox.iter().any(|(_, d)| d["t"] == "bye")).await;
    g.inbox.clear();
    h.inbox.clear();
    h.ready = true;
    until(&mut [&mut h, &mut g], "both back online", |gs| {
        gs[0].inbox.iter().any(|(_, d)| d["t"] == "welcome") && gs[1].inbox.iter().any(|(_, d)| d["t"] == "welcome")
    })
    .await;
    g.send(-2, false, json!({ "t": "again" }));
    until(&mut [&mut h, &mut g], "traffic after reconnect", |gs| gs[0].inbox.iter().any(|(_, d)| d["t"] == "again")).await;
}

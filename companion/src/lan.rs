//! Finding sessions on the local network.
//!
//! A hosting companion broadcasts a small UDP beacon once a second; every
//! companion listens for them and publishes what it hears to the game's menu,
//! so joining a friend in the same house is one click. (Broadcasts do not
//! cross the internet or a VPN such as Tailscale: there you type the address
//! once and it is remembered.)

use crate::bridge::{LanGame, SharedPublished};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;

pub const BEACON_PORT: u16 = 7778;
const BEACON_MAGIC: &str = "mistria-together";

#[derive(Serialize, Deserialize)]
struct Beacon {
    app: String,
    /// Distinguishes hosts behind one address and lets us ignore ourselves.
    id: String,
    name: String,
    port: u16,
    players: u32,
    locked: bool,
}

fn reusable_socket(port: u16) -> std::io::Result<UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    // Several companions on one machine (testing) must all hear beacons.
    socket.set_reuse_address(true)?;
    #[cfg(unix)]
    let _ = socket.set_reuse_port(true);
    socket.set_broadcast(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port)).into())?;
    UdpSocket::from_std(socket.into())
}

/// Listen for beacons for as long as the companion runs.
pub async fn listen(published: SharedPublished, own_id: String) {
    let socket = match reusable_socket(BEACON_PORT) {
        Ok(s) => s,
        Err(_) => return, // port taken by something else: no discovery, everything else works
    };
    let mut seen: HashMap<String, (LanGame, Instant)> = HashMap::new();
    let mut buf = [0u8; 1024];
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            res = socket.recv_from(&mut buf) => {
                let Ok((n, from)) = res else { continue };
                let Ok(b) = serde_json::from_slice::<Beacon>(&buf[..n]) else { continue };
                if b.app != BEACON_MAGIC || b.id == own_id || b.name.len() > 64 { continue; }
                let addr = if b.port == crate::proto::DEFAULT_PORT { from.ip().to_string() } else { format!("{}:{}", from.ip(), b.port) };
                seen.insert(b.id, (LanGame { name: b.name, addr, players: b.players, locked: b.locked }, Instant::now()));
            }
            _ = tick.tick() => {
                seen.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(4));
                let mut list: Vec<LanGame> = seen.values().map(|(g, _)| g.clone()).collect();
                list.sort_by(|a, b| a.name.cmp(&b.name).then(a.addr.cmp(&b.addr)));
                list.truncate(8);
                let mut p = published.lock().unwrap();
                if p.lan != list { p.lan = list; }
            }
        }
    }
}

/// Announce a hosted session until the returned task is aborted.
pub fn announce(id: String, name: String, port: u16, locked: bool, players: Arc<AtomicU32>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let Ok(socket) = reusable_socket(0) else { return };
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            let beacon = Beacon {
                app: BEACON_MAGIC.into(),
                id: id.clone(),
                name: name.clone(),
                port,
                players: players.load(Ordering::Relaxed),
                locked,
            };
            let Ok(bytes) = serde_json::to_vec(&beacon) else { continue };
            let _ = socket.send_to(&bytes, (Ipv4Addr::BROADCAST, BEACON_PORT)).await;
            // Also reach other companions on this very machine.
            let _ = socket.send_to(&bytes, (Ipv4Addr::LOCALHOST, BEACON_PORT)).await;
        }
    })
}

//! The companion's network side: one connection to a session hub, kept alive
//! for as long as the paired game has a save loaded.

use crate::blob::{self, Assembler};
use crate::bridge::{Control, GameInfo, OutMsg, SharedPublished, ToGame, ToNet};
use crate::hub::{Hub, HubConfig};
use crate::log;
use crate::proto::*;
use anyhow::{anyhow, Result};
use serde_json::json;
use std::net::SocketAddr;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::mpsc::{self, UnboundedReceiver};

#[derive(Debug, Clone)]
pub struct NetConfig {
    /// `host:port` of the hub to connect to.
    pub hub_addr: String,
    pub role: Role,
    pub password: Option<String>,
    pub host_key: Option<String>,
}

/// What the player wants the companion to be doing.
#[derive(Debug, Clone, PartialEq)]
pub enum Desired {
    Off,
    /// Host from this machine, or through a relay when `relay` is set.
    Host {
        port: u16,
        relay: Option<String>,
    },
    Join {
        addr: String,
    },
}

/// An embedded hub this companion is hosting on.
pub struct LocalHub {
    pub hub: Hub,
    pub key: String,
}

pub struct NetOptions {
    pub initial: Desired,
    pub password: Option<String>,
    /// A hub started ahead of time (so its port is known to the caller).
    pub hub: Option<LocalHub>,
    pub published: SharedPublished,
}

enum Ended {
    /// The game changed under us (quit, new save, went back to the title).
    Game(Option<GameInfo>),
    /// The player picked something else in the menu.
    Control(Control),
    /// The connection ended; tell the player why and retry.
    Lost(String),
    /// The bridge is gone: shut down.
    Stop,
}

const RETRY_DELAY: Duration = Duration::from_secs(3);
const UDP_OK_WINDOW: Duration = Duration::from_secs(6);

fn status(to_game: &Sender<ToGame>, state: &str, detail: impl Into<String>) {
    let _ = to_game.send(ToGame::Status {
        state: state.into(),
        detail: detail.into(),
    });
}

fn system(to_game: &Sender<ToGame>, value: serde_json::Value) {
    let _ = to_game.send(ToGame::Msg {
        from: -1,
        unreliable: false,
        json: value.to_string(),
    });
}

fn is_ready(game: &Option<GameInfo>) -> bool {
    game.as_ref().map(|g| g.ready).unwrap_or(false)
}

fn desired_from(control: &Control) -> Desired {
    let port = if control.port >= 1.0 && control.port <= 65535.0 {
        control.port as u16
    } else {
        DEFAULT_PORT
    };
    match control.mode.as_str() {
        "host" => Desired::Host { port, relay: None },
        "join" if !control.addr.trim().is_empty() => Desired::Join {
            addr: control.addr.trim().to_string(),
        },
        _ => Desired::Off,
    }
}

struct State {
    desired: Desired,
    password: Option<String>,
    game: Option<GameInfo>,
}

impl State {
    fn apply_control(&mut self, control: &Control) {
        self.desired = desired_from(control);
        self.password = Some(control.password.clone()).filter(|p| !p.is_empty());
    }

    /// Returns false when the bridge is gone.
    fn apply(&mut self, msg: Option<ToNet>) -> bool {
        match msg {
            Some(ToNet::Game(g)) => self.game = g,
            Some(ToNet::Control(c)) => self.apply_control(&c),
            Some(ToNet::Out(_)) => {}
            None => return false,
        }
        true
    }
}

/// Runs until the bridge goes away.
pub async fn run(
    opts: NetOptions,
    mut from_bridge: UnboundedReceiver<ToNet>,
    to_game: Sender<ToGame>,
) {
    let mut st = State {
        desired: opts.initial,
        password: opts.password,
        game: None,
    };
    let mut hub: Option<LocalHub> = opts.hub;
    let mut hub_password = st.password.clone();
    let published = opts.published;
    let beacon_id = crate::bridge::new_epoch();
    loop {
        {
            let mut p = published.lock().unwrap();
            (p.mode, p.addr) = match &st.desired {
                Desired::Off => ("off".to_string(), String::new()),
                Desired::Host { relay, .. } => {
                    ("host".to_string(), relay.clone().unwrap_or_default())
                }
                Desired::Join { addr } => ("join".to_string(), addr.clone()),
            };
        }

        // Keep the embedded hub in step with what is wanted.
        let want_port = match &st.desired {
            Desired::Host { port, relay: None } => Some(*port),
            _ => None,
        };
        match want_port {
            None => hub = None,
            Some(port) => {
                let stale = hub
                    .as_ref()
                    .map(|h| {
                        (port != 0 && h.hub.tcp_addr.port() != port) || hub_password != st.password
                    })
                    .unwrap_or(false);
                if stale {
                    hub = None;
                }
                if hub.is_none() {
                    let key = format!(
                        "{}{}",
                        crate::bridge::new_epoch(),
                        crate::bridge::new_epoch()
                    );
                    let cfg = HubConfig {
                        password: st.password.clone(),
                        host_key: Some(key.clone()),
                    };
                    match Hub::start(SocketAddr::from(([0, 0, 0, 0], port)), cfg).await {
                        Ok(started) => {
                            log!("hosting on port {}", started.tcp_addr.port());
                            hub_password = st.password.clone();
                            hub = Some(LocalHub { hub: started, key });
                        }
                        Err(e) => {
                            status(&to_game, "error", format!("cannot host: {e}"));
                            if !st.apply(from_bridge.recv().await) {
                                return;
                            }
                            continue;
                        }
                    }
                }
            }
        }

        if st.desired == Desired::Off || !is_ready(&st.game) {
            let detail = match (&st.desired, &st.game) {
                (Desired::Off, _) => "not connected",
                (_, None) => "waiting for the game",
                (_, Some(_)) => "waiting for you to load a save",
            };
            status(&to_game, "idle", detail);
            if !st.apply(from_bridge.recv().await) {
                return;
            }
            continue;
        }

        let info = st.game.clone().expect("ready game");
        let (cfg, announce) = match &st.desired {
            Desired::Host { relay: None, .. } => {
                let h = hub.as_ref().expect("hub running");
                let port = h.hub.tcp_addr.port();
                (
                    NetConfig {
                        hub_addr: format!("127.0.0.1:{port}"),
                        role: Role::Host,
                        password: st.password.clone(),
                        host_key: Some(h.key.clone()),
                    },
                    Some((beacon_id.clone(), port)),
                )
            }
            Desired::Host {
                relay: Some(addr), ..
            } => (
                NetConfig {
                    hub_addr: addr.clone(),
                    role: Role::Host,
                    password: st.password.clone(),
                    host_key: None,
                },
                None,
            ),
            Desired::Join { addr } => (
                NetConfig {
                    hub_addr: addr.clone(),
                    role: Role::Guest,
                    password: st.password.clone(),
                    host_key: None,
                },
                None,
            ),
            Desired::Off => unreachable!(),
        };
        status(
            &to_game,
            "connecting",
            format!("connecting to {}", cfg.hub_addr),
        );
        match session(&cfg, &info, announce, &mut from_bridge, &to_game).await {
            Ended::Stop => return,
            Ended::Game(g) => st.game = g,
            Ended::Control(c) => {
                system(&to_game, json!({ "t": "bye", "reason": "disconnected" }));
                st.apply_control(&c);
            }
            Ended::Lost(reason) => {
                log!("disconnected: {reason}");
                system(&to_game, json!({ "t": "bye", "reason": reason }));
                status(&to_game, "error", format!("{reason} - retrying"));
                let retry_at = tokio::time::Instant::now() + RETRY_DELAY;
                let before = (st.desired.clone(), st.game.as_ref().map(|g| g.sid.clone()));
                loop {
                    tokio::select! {
                        _ = tokio::time::sleep_until(retry_at) => break,
                        msg = from_bridge.recv() => {
                            if !st.apply(msg) { return; }
                            let now = (st.desired.clone(), st.game.as_ref().map(|g| g.sid.clone()));
                            if now != before || !is_ready(&st.game) { break; }
                        }
                    }
                }
            }
        }
    }
}

async fn resolve(addr: &str) -> Result<SocketAddr> {
    let with_port = if addr
        .rsplit_once(':')
        .map(|(_, p)| p.parse::<u16>().is_ok())
        .unwrap_or(false)
        && !addr.ends_with(']')
    {
        addr.to_string()
    } else {
        format!("{addr}:{DEFAULT_PORT}")
    };
    let mut addrs: Vec<SocketAddr> = tokio::net::lookup_host(&with_port)
        .await
        .map_err(|e| anyhow!("cannot resolve {with_port}: {e}"))?
        .collect();
    addrs.sort_by_key(|a| !a.is_ipv4());
    addrs
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("{with_port} has no address"))
}

async fn connect(cfg: &NetConfig, info: &GameInfo) -> Result<(TcpStream, Welcome, SocketAddr)> {
    let addr = resolve(&cfg.hub_addr).await?;
    let mut stream = tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(addr))
        .await
        .map_err(|_| {
            anyhow!("no answer from {addr} (is the host running, and the port reachable?)")
        })?
        .map_err(|e| anyhow!("cannot reach {addr}: {e}"))?;
    let _ = stream.set_nodelay(true);
    let hello = Frame::Hello(Hello {
        wire: WIRE_VERSION,
        game_proto: info.proto,
        mod_version: info.mod_version.clone(),
        name: if info.name.is_empty() {
            "Player".into()
        } else {
            info.name.clone()
        },
        role: cfg.role,
        password: cfg.password.clone(),
        host_key: cfg.host_key.clone(),
    });
    write_frame(&mut stream, &hello).await?;
    match tokio::time::timeout(Duration::from_secs(8), read_frame(&mut stream)).await {
        Ok(Ok(Frame::Welcome(w))) => Ok((stream, w, addr)),
        Ok(Ok(Frame::Bye { reason })) => Err(anyhow!("{reason}")),
        Ok(Ok(_)) => Err(anyhow!(
            "unexpected reply from {addr} (is that a Mistria Together host?)"
        )),
        Ok(Err(e)) => Err(anyhow!("connection to {addr} failed: {e}")),
        Err(_) => Err(anyhow!("{addr} did not answer the handshake")),
    }
}

async fn session(
    cfg: &NetConfig,
    info: &GameInfo,
    announce: Option<(String, u16)>,
    from_bridge: &mut UnboundedReceiver<ToNet>,
    to_game: &Sender<ToGame>,
) -> Ended {
    let current = match cfg.role {
        Role::Host if cfg.host_key.is_some() => "host",
        Role::Host => "host-relay",
        Role::Guest => "join",
    };
    let (stream, welcome, hub_addr) = match connect(cfg, info).await {
        Ok(v) => v,
        Err(e) => return Ended::Lost(e.to_string()),
    };
    let (mut rd, mut wr) = stream.into_split();
    let me = welcome.id;
    log!(
        "connected to {hub_addr} as player {me}{}",
        if welcome.host == me {
            " (host)".to_string()
        } else {
            format!(", host is player {}", welcome.host)
        }
    );
    system(
        to_game,
        json!({ "t": "welcome", "id": me, "host": welcome.host, "peers": welcome.peers }),
    );
    let connected_state = if cfg.role == Role::Host {
        "hosting"
    } else {
        "connected"
    };
    status(
        to_game,
        connected_state,
        format!("{} player(s) online", welcome.peers.len() + 1),
    );
    let mut peer_count = welcome.peers.len() + 1;
    let players = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(peer_count as u32));
    let beacon = announce.map(|(id, port)| {
        let name = if info.name.is_empty() {
            "Player".to_string()
        } else {
            info.name.clone()
        };
        crate::lan::announce(id, name, port, cfg.password.is_some(), players.clone())
    });

    // All TCP writes go through one task so big file transfers interleave
    // with ordinary messages instead of blocking them.
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(256);
    let writer = tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        while let Some(bytes) = rx.recv().await {
            if wr.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });

    let bind: SocketAddr = if hub_addr.is_ipv4() {
        "0.0.0.0:0".parse().unwrap()
    } else {
        "[::]:0".parse().unwrap()
    };
    let udp = match UdpSocket::bind(bind).await {
        Ok(s) => {
            let _ = s.connect(hub_addr).await;
            Some(s)
        }
        Err(_) => None,
    };
    let mut udp_acked: Option<Instant> = None;
    let mut udp_buf = vec![0u8; 2048];
    let mut assembler = Assembler::new(info.dir.clone());
    let mut blob_id: u32 = 0;
    let started = Instant::now();
    let mut rtt_ms: u32 = 0;
    let mut last_frame = Instant::now();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let mut ticks: u64 = 0;

    let ended = loop {
        tokio::select! {
            frame = read_frame(&mut rd) => {
                let frame = match frame {
                    Ok(f) => f,
                    Err(_) => break Ended::Lost("connection to the host was lost".into()),
                };
                last_frame = Instant::now();
                match frame {
                    Frame::Relay { peer, kind: RelayKind::Blob, payload } => {
                        match assembler.push(peer, &payload) {
                            Ok(Some(done)) => system(to_game, json!({
                                "t": "blob", "from": peer, "kind": done.kind, "file": done.file, "meta": done.meta,
                            })),
                            Ok(None) => {}
                            Err(e) => log!("dropped a file transfer from player {peer}: {e}"),
                        }
                    }
                    Frame::Relay { peer, kind, payload } => {
                        // Never hand the game something that is not JSON: one
                        // bad message would poison the whole batch it rides in.
                        if serde_json::from_slice::<&serde_json::value::RawValue>(&payload).is_ok() {
                            let json = String::from_utf8(payload).unwrap_or_default();
                            let _ = to_game.send(ToGame::Msg { from: peer as i32, unreliable: kind == RelayKind::Unreliable, json });
                        }
                    }
                    Frame::PeerJoined(p) => {
                        peer_count += 1;
                        log!("{} joined (player {})", p.name, p.id);
                        system(to_game, json!({ "t": "join", "id": p.id, "name": p.name }));
                        status(to_game, connected_state, format!("{peer_count} player(s) online"));
                    }
                    Frame::PeerLeft { id } => {
                        peer_count = peer_count.saturating_sub(1).max(1);
                        log!("player {id} left");
                        assembler.forget(id);
                        system(to_game, json!({ "t": "leave", "id": id }));
                        status(to_game, connected_state, format!("{peer_count} player(s) online"));
                    }
                    Frame::Stats { pings } => {
                        // Latency to another player is our leg plus theirs.
                        let own = pings.iter().find(|p| p.id == me).map(|p| p.ms).unwrap_or(rtt_ms);
                        let list: Vec<_> = pings.iter().filter(|p| p.id != me)
                            .map(|p| json!({ "id": p.id, "ms": (p.ms + own) / 2 })).collect();
                        let _ = to_game.send(ToGame::Msg { from: -1, unreliable: true, json: json!({ "t": "stat", "pings": list }).to_string() });
                    }
                    Frame::Pong { t } => {
                        let now = started.elapsed().as_millis() as u64;
                        rtt_ms = now.saturating_sub(t).min(60_000) as u32;
                    }
                    Frame::Bye { reason } => break Ended::Lost(reason),
                    _ => {}
                }
            }
            res = async { udp.as_ref().unwrap().recv(&mut udp_buf).await }, if udp.is_some() => {
                let Ok(n) = res else { continue };
                let Some(pkt) = parse_udp(&udp_buf[..n]) else { continue };
                if pkt.token != welcome.udp_token { continue; }
                match pkt.kind {
                    UDP_ACK => udp_acked = Some(Instant::now()),
                    UDP_RELAY if pkt.body.len() > 1 => {
                        udp_acked = Some(Instant::now());
                        let payload = &pkt.body[1..];
                        if serde_json::from_slice::<&serde_json::value::RawValue>(payload).is_ok() {
                            let _ = to_game.send(ToGame::Msg {
                                from: pkt.body[0] as i32,
                                unreliable: true,
                                json: String::from_utf8_lossy(payload).into_owned(),
                            });
                        }
                    }
                    _ => {}
                }
            }
            msg = from_bridge.recv() => {
                match msg {
                    None => break Ended::Stop,
                    Some(ToNet::Game(g)) => {
                        let same = g.as_ref().map(|g| g.sid == info.sid && g.ready && g.dir == info.dir).unwrap_or(false);
                        if !same { break Ended::Game(g); }
                    }
                    Some(ToNet::Control(c)) => {
                        // Re-selecting what is already running changes nothing.
                        let wanted = desired_from(&c);
                        let same = match (&wanted, current) {
                            (Desired::Host { relay: None, .. }, "host") => true,
                            (Desired::Join { addr }, "join") => *addr == cfg.hub_addr,
                            _ => false,
                        } && Some(c.password.clone()).filter(|p| !p.is_empty()) == cfg.password;
                        if !same { break Ended::Control(c); }
                    }
                    Some(ToNet::Out(OutMsg::Peer { to, unreliable, json })) => {
                        let udp_ok = udp_acked.map(|t| t.elapsed() < UDP_OK_WINDOW).unwrap_or(false);
                        if unreliable && udp_ok && json.len() <= MAX_DATAGRAM_PAYLOAD {
                            let pkt = udp_packet(welcome.udp_token, UDP_RELAY, Some(to), json.as_bytes());
                            let _ = udp.as_ref().unwrap().try_send(&pkt);
                        } else {
                            let kind = if unreliable { RelayKind::Unreliable } else { RelayKind::Msg };
                            let frame = Frame::Relay { peer: to, kind, payload: json.into_bytes() }.encode();
                            if unreliable {
                                // Droppable traffic must never block the loop.
                                let _ = tx.try_send(frame);
                            } else if tx.send(frame).await.is_err() {
                                break Ended::Lost("connection to the host was lost".into());
                            }
                        }
                    }
                    Some(ToNet::Out(OutMsg::Link(req))) => {
                        if req.get("t").and_then(|t| t.as_str()) == Some("blob") {
                            blob_id = blob_id.wrapping_add(1);
                            let (dir, tx, id) = (info.dir.clone(), tx.clone(), blob_id);
                            tokio::spawn(async move {
                                if let Err(e) = blob::send(&dir, &req, id, tx).await {
                                    log!("file transfer failed: {e}");
                                }
                            });
                        }
                    }
                }
            }
            _ = tick.tick() => {
                ticks += 1;
                players.store(peer_count as u32, std::sync::atomic::Ordering::Relaxed);
                if last_frame.elapsed() > Duration::from_secs(15) {
                    break Ended::Lost("the host stopped responding".into());
                }
                if let Some(udp) = &udp {
                    let _ = udp.try_send(&udp_packet(welcome.udp_token, UDP_HELLO, None, &[]));
                }
                if ticks.is_multiple_of(2) {
                    let ping = Frame::Ping { t: started.elapsed().as_millis() as u64, rtt_ms }.encode();
                    if tx.try_send(ping).is_err() && tx.is_closed() {
                        break Ended::Lost("connection to the host was lost".into());
                    }
                }
            }
        }
    };
    drop(tx);
    if let Some(beacon) = beacon {
        beacon.abort();
    }
    writer.abort();
    assembler.cleanup();
    ended
}

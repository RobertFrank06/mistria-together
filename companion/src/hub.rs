//! The session hub: every player's companion connects here and the hub
//! forwards traffic between them. The host's companion runs one in-process;
//! `mistria-together relay` runs one standalone for people who cannot open a
//! port (both players then connect outwards to it).

use crate::log;
use crate::proto::*;
use anyhow::{anyhow, bail, Result};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::mpsc;

#[derive(Debug, Clone, Default)]
pub struct HubConfig {
    pub password: Option<String>,
    /// When set, only a client presenting this key may take the host role.
    pub host_key: Option<String>,
}

const QUEUE_LIMIT: usize = 8192;
const UDP_FRESH: Duration = Duration::from_secs(8);

struct Peer {
    name: String,
    tx: mpsc::Sender<Arc<Vec<u8>>>,
    udp_token: u64,
    udp_addr: Option<SocketAddr>,
    udp_seen: Instant,
    rtt_ms: u32,
}

#[derive(Default)]
struct State {
    peers: HashMap<u8, Peer>,
    tokens: HashMap<u64, u8>,
    host: Option<u8>,
    next_id: u8,
    game_proto: Option<u32>,
}

type Shared = Arc<Mutex<State>>;

pub struct Hub {
    pub tcp_addr: SocketAddr,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    state: Shared,
}

impl Hub {
    /// Bind TCP and UDP on the same port and start serving.
    pub async fn start(bind: SocketAddr, cfg: HubConfig) -> Result<Hub> {
        let listener = TcpListener::bind(bind).await.map_err(|e| anyhow!("cannot listen on {bind}: {e}"))?;
        let tcp_addr = listener.local_addr()?;
        let udp = UdpSocket::bind(tcp_addr).await.map_err(|e| anyhow!("cannot bind UDP {tcp_addr}: {e}"))?;
        let udp = Arc::new(udp);
        let state: Shared = Arc::new(Mutex::new(State { next_id: 1, ..Default::default() }));
        let cfg = Arc::new(cfg);

        let udp_task = tokio::spawn(udp_loop(udp.clone(), state.clone()));
        let stats_task = tokio::spawn(stats_loop(state.clone()));
        let accept_state = state.clone();
        let accept_task = tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, addr)) => {
                        let _ = stream.set_nodelay(true);
                        tokio::spawn(serve(stream, addr, accept_state.clone(), udp.clone(), cfg.clone()));
                    }
                    Err(e) => {
                        log!("hub: accept failed: {e}");
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        });
        Ok(Hub { tcp_addr, tasks: vec![accept_task, udp_task, stats_task], state })
    }

    pub fn stop(&self) {
        for task in &self.tasks {
            task.abort();
        }
        // Dropping the peers closes their queues, which ends their connections.
        let mut st = self.state.lock().unwrap();
        st.peers.clear();
        st.tokens.clear();
        st.host = None;
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.stop();
    }
}

fn random_token() -> u64 {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut h = RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    h.finish() | 1
}

/// Queue an encoded frame for a peer. A peer whose queue is full is too far
/// behind to ever catch up, so it is dropped rather than buffering forever.
fn push(state: &mut State, id: u8, bytes: &Arc<Vec<u8>>) {
    let full = match state.peers.get(&id) {
        Some(p) => p.tx.try_send(bytes.clone()).is_err(),
        None => false,
    };
    if full {
        log!("hub: player {id} cannot keep up, dropping connection");
        state.peers.remove(&id);
    }
}

fn targets(state: &State, from: u8, to: u8) -> Vec<u8> {
    match to {
        TO_ALL => state.peers.keys().copied().filter(|&id| id != from).collect(),
        TO_HOST => state.host.into_iter().filter(|&id| id != from).collect(),
        id if id != from && state.peers.contains_key(&id) => vec![id],
        _ => Vec::new(),
    }
}

/// Deliver an unreliable payload: over UDP where the receiver has a working
/// UDP path, otherwise over its TCP stream.
fn relay_unreliable(state: &mut State, udp: &UdpSocket, from: u8, to: u8, payload: &[u8]) {
    let now = Instant::now();
    let mut tcp_fallback: Option<Arc<Vec<u8>>> = None;
    for id in targets(state, from, to) {
        let Some(peer) = state.peers.get(&id) else { continue };
        match peer.udp_addr {
            Some(addr) if now.duration_since(peer.udp_seen) < UDP_FRESH && payload.len() <= MAX_DATAGRAM_PAYLOAD => {
                let pkt = udp_packet(peer.udp_token, UDP_RELAY, Some(from), payload);
                let _ = udp.try_send_to(&pkt, addr);
            }
            _ => {
                let bytes = tcp_fallback.get_or_insert_with(|| {
                    Arc::new(Frame::Relay { peer: from, kind: RelayKind::Unreliable, payload: payload.to_vec() }.encode())
                });
                let bytes = bytes.clone();
                push(state, id, &bytes);
            }
        }
    }
}

async fn udp_loop(udp: Arc<UdpSocket>, state: Shared) {
    let mut buf = vec![0u8; 2048];
    loop {
        let (n, addr) = match udp.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(_) => {
                // Windows reports ICMP port-unreachable as an error here.
                tokio::time::sleep(Duration::from_millis(5)).await;
                continue;
            }
        };
        let Some(pkt) = parse_udp(&buf[..n]) else { continue };
        let mut st = state.lock().unwrap();
        let Some(&id) = st.tokens.get(&pkt.token) else { continue };
        let Some(peer) = st.peers.get_mut(&id) else { continue };
        peer.udp_addr = Some(addr);
        peer.udp_seen = Instant::now();
        match pkt.kind {
            UDP_HELLO => {
                let ack = udp_packet(pkt.token, UDP_ACK, None, &[]);
                let _ = udp.try_send_to(&ack, addr);
            }
            UDP_RELAY if !pkt.body.is_empty() => {
                let to = pkt.body[0];
                relay_unreliable(&mut st, &udp, id, to, &pkt.body[1..]);
            }
            _ => {}
        }
    }
}

async fn stats_loop(state: Shared) {
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    loop {
        tick.tick().await;
        let mut st = state.lock().unwrap();
        if st.peers.len() < 2 {
            continue;
        }
        let pings: Vec<PeerPing> = st.peers.iter().map(|(&id, p)| PeerPing { id, ms: p.rtt_ms }).collect();
        let bytes = Arc::new(Frame::Stats { pings }.encode());
        let ids: Vec<u8> = st.peers.keys().copied().collect();
        for id in ids {
            push(&mut st, id, &bytes);
        }
    }
}

async fn serve(stream: TcpStream, addr: SocketAddr, state: Shared, udp: Arc<UdpSocket>, cfg: Arc<HubConfig>) {
    let (mut rd, mut wr) = stream.into_split();
    let hello = match tokio::time::timeout(Duration::from_secs(8), read_frame(&mut rd)).await {
        Ok(Ok(Frame::Hello(h))) => h,
        _ => return,
    };

    let (tx, mut rx) = mpsc::channel::<Arc<Vec<u8>>>(QUEUE_LIMIT);
    let admitted = admit(&state, &cfg, &hello, tx);
    let (id, welcome) = match admitted {
        Ok(v) => v,
        Err(e) => {
            log!("hub: refused {} from {addr}: {e}", hello.name);
            let _ = write_frame(&mut wr, &Frame::Bye { reason: e.to_string() }).await;
            return;
        }
    };
    log!("hub: {} joined as player {id} ({:?}) from {addr}", hello.name, hello.role);
    if write_frame(&mut wr, &Frame::Welcome(welcome)).await.is_err() {
        remove_peer(&state, id, "connection lost");
        return;
    }

    let writer = tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        while let Some(bytes) = rx.recv().await {
            if wr.write_all(&bytes).await.is_err() {
                break;
            }
        }
        let _ = wr.shutdown().await;
    });

    loop {
        // A silent connection is a dead one: clients ping every two seconds.
        let frame = match tokio::time::timeout(Duration::from_secs(20), read_frame(&mut rd)).await {
            Ok(Ok(f)) => f,
            _ => break,
        };
        let mut st = state.lock().unwrap();
        if !st.peers.contains_key(&id) {
            break;
        }
        match frame {
            Frame::Relay { peer: to, kind: RelayKind::Unreliable, payload } => {
                relay_unreliable(&mut st, &udp, id, to, &payload);
            }
            Frame::Relay { peer: to, kind, payload } => {
                let bytes = Arc::new(Frame::Relay { peer: id, kind, payload }.encode());
                for target in targets(&st, id, to) {
                    push(&mut st, target, &bytes);
                }
            }
            Frame::Ping { t, rtt_ms } => {
                if let Some(p) = st.peers.get_mut(&id) {
                    p.rtt_ms = rtt_ms;
                }
                let bytes = Arc::new(Frame::Pong { t }.encode());
                push(&mut st, id, &bytes);
            }
            _ => {}
        }
    }

    remove_peer(&state, id, "left");
    // Dropping the peer dropped its sender; the writer drains and exits.
    let _ = tokio::time::timeout(Duration::from_secs(2), writer).await;
}

fn admit(state: &Shared, cfg: &HubConfig, hello: &Hello, tx: mpsc::Sender<Arc<Vec<u8>>>) -> Result<(u8, Welcome)> {
    if hello.wire != WIRE_VERSION {
        bail!("companion version mismatch (theirs speaks protocol {}, this session {WIRE_VERSION}) - update Mistria Together on both sides", hello.wire);
    }
    if let Some(pw) = &cfg.password {
        if hello.password.as_deref() != Some(pw.as_str()) {
            bail!("wrong password");
        }
    }
    let mut st = state.lock().unwrap();
    if st.peers.is_empty() {
        st.game_proto = None;
    }
    match hello.role {
        Role::Host => {
            if let Some(key) = &cfg.host_key {
                if hello.host_key.as_deref() != Some(key.as_str()) {
                    bail!("only the player who started this session can host it");
                }
            }
            if st.host.is_some() {
                bail!("this session already has a host");
            }
        }
        Role::Guest => {
            if st.host.is_none() {
                bail!("the host is not in the game yet");
            }
        }
    }
    if let Some(proto) = st.game_proto {
        if proto != hello.game_proto {
            bail!("mod version mismatch ({} is on a different version of Mistria Together)", hello.name);
        }
    }
    if st.peers.len() >= MAX_PEERS {
        bail!("the session is full");
    }
    let mut id = st.next_id;
    while id == 0 || id >= TO_HOST || st.peers.contains_key(&id) {
        id = id.wrapping_add(1);
    }
    st.next_id = id.wrapping_add(1);
    st.game_proto = Some(hello.game_proto);
    if hello.role == Role::Host {
        st.host = Some(id);
    }

    let mut udp_token = random_token();
    while st.tokens.contains_key(&udp_token) {
        udp_token = udp_token.wrapping_add(2);
    }
    let roster: Vec<PeerInfo> = st.peers.iter().map(|(&pid, p)| PeerInfo { id: pid, name: p.name.clone() }).collect();
    let joined = Arc::new(Frame::PeerJoined(PeerInfo { id, name: hello.name.clone() }).encode());
    let others: Vec<u8> = st.peers.keys().copied().collect();
    for other in others {
        push(&mut st, other, &joined);
    }
    st.tokens.insert(udp_token, id);
    st.peers.insert(
        id,
        Peer { name: hello.name.clone(), tx, udp_token, udp_addr: None, udp_seen: Instant::now(), rtt_ms: 0 },
    );
    let host = st.host.unwrap_or(0);
    Ok((id, Welcome { id, host, udp_token, peers: roster }))
}

fn remove_peer(state: &Shared, id: u8, why: &str) {
    let mut st = state.lock().unwrap();
    if let Some(peer) = st.peers.remove(&id) {
        st.tokens.remove(&peer.udp_token);
        log!("hub: {} (player {id}) {why}", peer.name);
    } else {
        // Already dropped (queue overflow): still clear its token.
        st.tokens.retain(|_, v| *v != id);
    }
    let left = Arc::new(Frame::PeerLeft { id }.encode());
    let others: Vec<u8> = st.peers.keys().copied().collect();
    if st.host == Some(id) {
        // The world lives in the host's game: without it there is no session.
        st.host = None;
        let bye = Arc::new(Frame::Bye { reason: "the host left".into() }.encode());
        for other in others {
            push(&mut st, other, &bye);
            st.peers.remove(&other);
        }
        st.tokens.clear();
    } else {
        for other in others {
            push(&mut st, other, &left);
        }
    }
}

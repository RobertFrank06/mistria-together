//! Wire protocol between a companion and a session hub.
//!
//! TCP carries length-prefixed frames: `[u32 len][u8 kind][body]`. Control
//! frames have JSON bodies; relay frames carry an opaque payload from one
//! game to others. UDP carries the same relay payloads for traffic that is
//! allowed to get lost (player movement), so it never waits behind a resend.

use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Version of the companion <-> hub protocol in this file.
pub const WIRE_VERSION: u32 = 1;
/// Largest frame either side accepts. Blobs are chunked far below this.
pub const MAX_FRAME: usize = 2 * 1024 * 1024;
/// Largest payload sent as a single UDP datagram (stays under common MTUs).
pub const MAX_DATAGRAM_PAYLOAD: usize = 1150;
pub const UDP_MAGIC: [u8; 4] = *b"MTG1";
pub const DEFAULT_PORT: u16 = 7777;
pub const MAX_PEERS: usize = 8;

/// Address meaning "every other peer".
pub const TO_ALL: u8 = 255;
/// Address meaning "whoever is hosting".
pub const TO_HOST: u8 = 254;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Host,
    Guest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Hello {
    pub wire: u32,
    /// The mod's own message version (`MT_PROTO` in the GML). Peers must match.
    pub game_proto: u32,
    pub mod_version: String,
    pub name: String,
    pub role: Role,
    #[serde(default)]
    pub password: Option<String>,
    /// Proves that this client is the one that started an embedded hub.
    #[serde(default)]
    pub host_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PeerInfo {
    pub id: u8,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Welcome {
    pub id: u8,
    pub host: u8,
    pub udp_token: u64,
    pub peers: Vec<PeerInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PeerPing {
    pub id: u8,
    pub ms: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RelayKind {
    /// A JSON message from one game to another, delivered in order.
    Msg = 0,
    /// A JSON message that may be dropped (it arrived here over TCP only
    /// because UDP is not usable for one side).
    Unreliable = 1,
    /// One chunk of a file transfer.
    Blob = 2,
}

impl RelayKind {
    fn from_u8(v: u8) -> Result<Self> {
        Ok(match v {
            0 => RelayKind::Msg,
            1 => RelayKind::Unreliable,
            2 => RelayKind::Blob,
            _ => bail!("unknown relay kind {v}"),
        })
    }
}

#[derive(Debug, Clone)]
pub enum Frame {
    Hello(Hello),
    Welcome(Welcome),
    /// Sent before the hub closes a connection, with a reason for the player.
    Bye { reason: String },
    PeerJoined(PeerInfo),
    PeerLeft { id: u8 },
    /// `t` is echoed back; `rtt_ms` is the sender's last measured round trip.
    Ping { t: u64, rtt_ms: u32 },
    Pong { t: u64 },
    Stats { pings: Vec<PeerPing> },
    /// Client to hub: `peer` is the destination. Hub to client: the sender.
    Relay { peer: u8, kind: RelayKind, payload: Vec<u8> },
}

const K_HELLO: u8 = 1;
const K_WELCOME: u8 = 2;
const K_BYE: u8 = 3;
const K_JOINED: u8 = 4;
const K_LEFT: u8 = 5;
const K_PING: u8 = 6;
const K_PONG: u8 = 7;
const K_STATS: u8 = 8;
const K_RELAY: u8 = 9;

#[derive(Serialize, Deserialize)]
struct ByeBody {
    reason: String,
}
#[derive(Serialize, Deserialize)]
struct LeftBody {
    id: u8,
}
#[derive(Serialize, Deserialize)]
struct PingBody {
    t: u64,
    #[serde(default)]
    rtt_ms: u32,
}
#[derive(Serialize, Deserialize)]
struct StatsBody {
    pings: Vec<PeerPing>,
}

impl Frame {
    /// Encode including the 4-byte length prefix.
    pub fn encode(&self) -> Vec<u8> {
        fn json<T: Serialize>(kind: u8, body: &T) -> Vec<u8> {
            let mut out = vec![0, 0, 0, 0, kind];
            serde_json::to_writer(&mut out, body).expect("serialize control frame");
            out
        }
        let mut out = match self {
            Frame::Hello(h) => json(K_HELLO, h),
            Frame::Welcome(w) => json(K_WELCOME, w),
            Frame::Bye { reason } => json(K_BYE, &ByeBody { reason: reason.clone() }),
            Frame::PeerJoined(p) => json(K_JOINED, p),
            Frame::PeerLeft { id } => json(K_LEFT, &LeftBody { id: *id }),
            Frame::Ping { t, rtt_ms } => json(K_PING, &PingBody { t: *t, rtt_ms: *rtt_ms }),
            Frame::Pong { t } => json(K_PONG, &PingBody { t: *t, rtt_ms: 0 }),
            Frame::Stats { pings } => json(K_STATS, &StatsBody { pings: pings.clone() }),
            Frame::Relay { peer, kind, payload } => {
                let mut out = Vec::with_capacity(7 + payload.len());
                out.extend_from_slice(&[0, 0, 0, 0, K_RELAY, *peer, *kind as u8]);
                out.extend_from_slice(payload);
                out
            }
        };
        let len = (out.len() - 4) as u32;
        out[..4].copy_from_slice(&len.to_be_bytes());
        out
    }

    /// Decode a frame body (everything after the length prefix).
    pub fn decode(buf: &[u8]) -> Result<Frame> {
        let (&kind, body) = buf.split_first().ok_or_else(|| anyhow!("empty frame"))?;
        Ok(match kind {
            K_HELLO => Frame::Hello(serde_json::from_slice(body)?),
            K_WELCOME => Frame::Welcome(serde_json::from_slice(body)?),
            K_BYE => Frame::Bye { reason: serde_json::from_slice::<ByeBody>(body)?.reason },
            K_JOINED => Frame::PeerJoined(serde_json::from_slice(body)?),
            K_LEFT => Frame::PeerLeft { id: serde_json::from_slice::<LeftBody>(body)?.id },
            K_PING => {
                let b: PingBody = serde_json::from_slice(body)?;
                Frame::Ping { t: b.t, rtt_ms: b.rtt_ms }
            }
            K_PONG => Frame::Pong { t: serde_json::from_slice::<PingBody>(body)?.t },
            K_STATS => Frame::Stats { pings: serde_json::from_slice::<StatsBody>(body)?.pings },
            K_RELAY => {
                if body.len() < 2 {
                    bail!("short relay frame");
                }
                Frame::Relay { peer: body[0], kind: RelayKind::from_u8(body[1])?, payload: body[2..].to_vec() }
            }
            other => bail!("unknown frame kind {other}"),
        })
    }
}

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Frame> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let len = u32::from_be_bytes(len) as usize;
    if len == 0 || len > MAX_FRAME {
        bail!("bad frame length {len}");
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    Frame::decode(&buf)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &Frame) -> Result<()> {
    w.write_all(&frame.encode()).await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// UDP datagrams: [magic 4][token 8][kind 1][body]
// ---------------------------------------------------------------------------

pub const UDP_HELLO: u8 = 1; // client -> hub, no body
pub const UDP_ACK: u8 = 2; // hub -> client, no body
pub const UDP_RELAY: u8 = 3; // body: [peer u8][payload]

pub fn udp_packet(token: u64, kind: u8, peer: Option<u8>, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(14 + payload.len());
    out.extend_from_slice(&UDP_MAGIC);
    out.extend_from_slice(&token.to_be_bytes());
    out.push(kind);
    if let Some(p) = peer {
        out.push(p);
    }
    out.extend_from_slice(payload);
    out
}

pub struct UdpPacket<'a> {
    pub token: u64,
    pub kind: u8,
    pub body: &'a [u8],
}

pub fn parse_udp(buf: &[u8]) -> Option<UdpPacket<'_>> {
    if buf.len() < 13 || buf[..4] != UDP_MAGIC {
        return None;
    }
    let token = u64::from_be_bytes(buf[4..12].try_into().ok()?);
    Some(UdpPacket { token, kind: buf[12], body: &buf[13..] })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip() {
        let frames = vec![
            Frame::Hello(Hello {
                wire: WIRE_VERSION,
                game_proto: 1,
                mod_version: "0.1.0".into(),
                name: "Ari".into(),
                role: Role::Guest,
                password: Some("pw".into()),
                host_key: None,
            }),
            Frame::Welcome(Welcome { id: 2, host: 1, udp_token: 42, peers: vec![PeerInfo { id: 1, name: "H".into() }] }),
            Frame::Bye { reason: "host left".into() },
            Frame::PeerLeft { id: 3 },
            Frame::Ping { t: 99, rtt_ms: 12 },
            Frame::Stats { pings: vec![PeerPing { id: 1, ms: 20 }] },
            Frame::Relay { peer: TO_ALL, kind: RelayKind::Blob, payload: vec![1, 2, 3, 0, 255] },
        ];
        for f in frames {
            let enc = f.encode();
            let len = u32::from_be_bytes(enc[..4].try_into().unwrap()) as usize;
            assert_eq!(len, enc.len() - 4);
            let dec = Frame::decode(&enc[4..]).unwrap();
            assert_eq!(format!("{f:?}"), format!("{dec:?}"));
        }
    }

    #[test]
    fn udp_round_trip() {
        let p = udp_packet(7, UDP_RELAY, Some(TO_ALL), b"{}");
        let parsed = parse_udp(&p).unwrap();
        assert_eq!(parsed.token, 7);
        assert_eq!(parsed.kind, UDP_RELAY);
        assert_eq!(parsed.body, &[TO_ALL, b'{', b'}']);
        assert!(parse_udp(b"nope").is_none());
    }
}

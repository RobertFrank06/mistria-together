//! Mistria Together companion: the networking half of the co-op mod.
//!
//! The mod inside the game cannot open sockets, so this program does it on
//! its behalf: it talks to the game through files ([`bridge`]) and to other
//! players through a session hub ([`hub`], [`client`]).

pub mod blob;
pub mod bridge;
pub mod client;
pub mod hub;
pub mod paths;
pub mod proto;

use anyhow::Result;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[doc(hidden)]
pub fn log_line(args: std::fmt::Arguments<'_>) {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    println!("[{:02}:{:02}:{:02}] {}", (secs / 3600) % 24, (secs / 60) % 60, secs % 60, args);
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { $crate::log_line(format_args!($($arg)*)) };
}

#[derive(Debug, Clone)]
pub enum Mode {
    /// Host a session. With `relay` set the session lives on that remote hub
    /// instead of one started here.
    Host { port: u16, relay: Option<String> },
    /// Join the session at `addr`.
    Join { addr: String },
}

#[derive(Debug, Clone)]
pub struct Options {
    pub mode: Mode,
    pub password: Option<String>,
    /// Directories a game may exchange files in.
    pub ipc_dirs: Vec<PathBuf>,
}

/// A running companion. Dropping it shuts everything down.
pub struct Companion {
    /// Address of the embedded hub when hosting locally.
    pub hub_addr: Option<SocketAddr>,
    stop: Arc<AtomicBool>,
    hub: Option<hub::Hub>,
    net: tokio::task::JoinHandle<()>,
    bridge: Option<std::thread::JoinHandle<()>>,
}

impl Companion {
    pub async fn start(opts: Options) -> Result<Companion> {
        let mut hub = None;
        let mut hub_addr = None;
        let net_cfg = match &opts.mode {
            Mode::Host { port, relay: None } => {
                let host_key = format!("{}{}", bridge::new_epoch(), bridge::new_epoch());
                let started = hub::Hub::start(
                    SocketAddr::from(([0, 0, 0, 0], *port)),
                    hub::HubConfig { password: opts.password.clone(), host_key: Some(host_key.clone()) },
                )
                .await?;
                hub_addr = Some(started.tcp_addr);
                let local = format!("127.0.0.1:{}", started.tcp_addr.port());
                hub = Some(started);
                client::NetConfig { hub_addr: local, role: proto::Role::Host, password: opts.password.clone(), host_key: Some(host_key) }
            }
            Mode::Host { relay: Some(addr), .. } => {
                client::NetConfig { hub_addr: addr.clone(), role: proto::Role::Host, password: opts.password.clone(), host_key: None }
            }
            Mode::Join { addr } => {
                client::NetConfig { hub_addr: addr.clone(), role: proto::Role::Guest, password: opts.password.clone(), host_key: None }
            }
        };

        let (to_net, from_bridge) = tokio::sync::mpsc::unbounded_channel();
        let (to_game, from_net) = std::sync::mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let bridge = bridge::Bridge::new(opts.ipc_dirs.clone(), to_net, from_net, stop.clone());
        let bridge = std::thread::Builder::new().name("bridge".into()).spawn(move || bridge.run())?;
        let net = tokio::spawn(client::run(net_cfg, from_bridge, to_game));
        Ok(Companion { hub_addr, stop, hub, net, bridge: Some(bridge) })
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.net.abort();
        if let Some(hub) = self.hub.take() {
            hub.stop();
        }
        if let Some(handle) = self.bridge.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Companion {
    fn drop(&mut self) {
        self.shutdown();
    }
}

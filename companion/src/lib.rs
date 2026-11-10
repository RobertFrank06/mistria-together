//! Mistria Together companion: the networking half of the co-op mod.
//!
//! The mod inside the game cannot open sockets, so this program does it on
//! its behalf: it talks to the game through files ([`bridge`]) and to other
//! players through a session hub ([`hub`], [`client`]).

pub mod blob;
pub mod bridge;
pub mod client;
pub mod hub;
pub mod install;
pub mod lan;
pub mod paths;
pub mod proto;

use anyhow::Result;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

static LOG_FILE: std::sync::Mutex<Option<std::fs::File>> = std::sync::Mutex::new(None);

/// Also write log lines to a file (the background companion has no window).
pub fn log_to_file(path: Option<PathBuf>) {
    let Some(path) = path else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    *LOG_FILE.lock().unwrap() = std::fs::File::create(path).ok();
}

#[doc(hidden)]
pub fn log_line(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let line = format!("[{:02}:{:02}:{:02}] {}", (secs / 3600) % 24, (secs / 60) % 60, secs % 60, args);
    println!("{line}");
    if let Some(file) = LOG_FILE.lock().unwrap().as_mut() {
        let _ = writeln!(file, "{line}");
    }
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { $crate::log_line(format_args!($($arg)*)) };
}

#[derive(Debug, Clone)]
pub enum Mode {
    /// Do nothing until the player picks Host or Join in the game's menu.
    /// This is how the companion runs in the background.
    Menu,
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
    /// Address of the embedded hub when started in host mode.
    pub hub_addr: Option<SocketAddr>,
    stop: Arc<AtomicBool>,
    net: tokio::task::JoinHandle<()>,
    lan: tokio::task::JoinHandle<()>,
    bridge: Option<std::thread::JoinHandle<()>>,
}

impl Companion {
    pub async fn start(opts: Options) -> Result<Companion> {
        let mut hub = None;
        let mut hub_addr = None;
        let initial = match &opts.mode {
            Mode::Menu => client::Desired::Off,
            Mode::Host { port, relay: None } => {
                // Started here rather than lazily so a busy port is reported at once.
                let key = format!("{}{}", bridge::new_epoch(), bridge::new_epoch());
                let started = hub::Hub::start(
                    SocketAddr::from(([0, 0, 0, 0], *port)),
                    hub::HubConfig { password: opts.password.clone(), host_key: Some(key.clone()) },
                )
                .await?;
                hub_addr = Some(started.tcp_addr);
                let actual = started.tcp_addr.port();
                hub = Some(client::LocalHub { hub: started, key });
                client::Desired::Host { port: actual, relay: None }
            }
            Mode::Host { port, relay: Some(addr) } => client::Desired::Host { port: *port, relay: Some(addr.clone()) },
            Mode::Join { addr } => client::Desired::Join { addr: addr.clone() },
        };

        let published: bridge::SharedPublished = Default::default();
        let (to_net, from_bridge) = tokio::sync::mpsc::unbounded_channel();
        let (to_game, from_net) = std::sync::mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let adopt = matches!(opts.mode, Mode::Menu);
        let bridge = bridge::Bridge::new(opts.ipc_dirs.clone(), to_net, from_net, stop.clone(), published.clone(), adopt);
        let bridge = std::thread::Builder::new().name("bridge".into()).spawn(move || bridge.run())?;
        let lan = tokio::spawn(lan::listen(published.clone(), bridge::new_epoch()));
        let net = tokio::spawn(client::run(
            client::NetOptions { initial, password: opts.password.clone(), hub, published },
            from_bridge,
            to_game,
        ));
        Ok(Companion { hub_addr, stop, net, lan, bridge: Some(bridge) })
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.net.abort();
        self.lan.abort();
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

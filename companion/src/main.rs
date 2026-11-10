use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use mistria_together::proto::DEFAULT_PORT;
use mistria_together::{hub, log, paths, Companion, Mode, Options};
use std::io::Write;
use std::net::{SocketAddr, UdpSocket};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "mistria-together", version, about = "Companion for the Mistria Together co-op mod.\n\nRun it next to Fields of Mistria: one player hosts, the others join.\nStart it without arguments for a guided setup.")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// The game's save-data folder, if it is not found automatically.
    #[arg(long, global = true, value_name = "DIR")]
    data_dir: Option<PathBuf>,

    /// Instance name, for running two games on one machine
    /// (the game reads it from MISTRIA_TOGETHER_INSTANCE).
    #[arg(long, global = true, value_name = "NAME")]
    instance: Option<String>,

    /// Session password. Everyone must use the same one.
    #[arg(long, global = true)]
    password: Option<String>,
}

#[derive(Subcommand)]
enum Command {
    /// Host a session from your game. Other players join your address.
    Host {
        /// Port to listen on (TCP and UDP).
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
        /// Host through a relay server instead of opening a port yourself.
        #[arg(long, value_name = "ADDR")]
        relay: Option<String>,
    },
    /// Join a session.
    Join {
        /// The host's (or relay's) address, e.g. 100.64.0.5 or example.net:7777.
        addr: String,
    },
    /// Run a standalone relay server. It needs no game: host and guests all
    /// connect to it, so nobody at home has to forward a port.
    Relay {
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
    },
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Remembered {
    #[serde(default)]
    last: String,
    #[serde(default)]
    addr: String,
}

fn prompt(text: &str) -> String {
    print!("{text}");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    line.trim().to_string()
}

/// No arguments (for example a double-click): ask what to do.
fn interactive(cli: &Cli) -> Result<Mode> {
    let file = paths::settings_file(cli.data_dir.as_deref());
    let mut mem: Remembered =
        file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    println!("Mistria Together {}", env!("CARGO_PKG_VERSION"));
    println!();
    println!("  1) Host - other players join your game");
    println!("  2) Join - connect to someone else's game");
    println!();
    let default = if mem.last == "join" { "2" } else { "1" };
    let mode = loop {
        let choice = prompt(&format!("Choose 1 or 2 [{default}]: "));
        let choice = if choice.is_empty() { default.to_string() } else { choice };
        match choice.as_str() {
            "1" | "h" | "host" => {
                mem.last = "host".into();
                break Mode::Host { port: DEFAULT_PORT, relay: None };
            }
            "2" | "j" | "join" => {
                let addr = loop {
                    let hint = if mem.addr.is_empty() { String::new() } else { format!(" [{}]", mem.addr) };
                    let addr = prompt(&format!("Host address{hint}: "));
                    let addr = if addr.is_empty() { mem.addr.clone() } else { addr };
                    if !addr.is_empty() {
                        break addr;
                    }
                };
                mem.last = "join".into();
                mem.addr = addr.clone();
                break Mode::Join { addr };
            }
            _ => {}
        }
    };
    if let Some(file) = file {
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(file, serde_json::to_vec_pretty(&mem)?);
    }
    println!();
    Ok(mode)
}

/// The local address the OS would use to reach `probe` (no packet is sent).
fn local_addr_towards(probe: &str) -> Option<std::net::IpAddr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect(probe).ok()?;
    socket.local_addr().ok().map(|a| a.ip()).filter(|ip| !ip.is_unspecified() && !ip.is_loopback())
}

fn print_host_addresses(port: u16) {
    let lan = local_addr_towards("192.0.2.1:9");
    // Tailscale's service address: routes via the tailnet interface if any.
    let tail = local_addr_towards("100.100.100.100:9").filter(|ip| match ip {
        std::net::IpAddr::V4(v4) => v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]),
        _ => false,
    });
    let suffix = if port == DEFAULT_PORT { String::new() } else { format!(":{port}") };
    log!("hosting on port {port} (TCP + UDP). Other players run:");
    if let Some(ip) = tail {
        log!("    mistria-together join {ip}{suffix}      (Tailscale)");
    }
    if let Some(ip) = lan.filter(|ip| Some(*ip) != tail) {
        log!("    mistria-together join {ip}{suffix}      (same network)");
    }
    if tail.is_none() {
        log!("    over the internet: your public address, with port {port} forwarded - or use Tailscale / a relay");
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    if let Some(Command::Relay { port }) = &cli.command {
        let hub = hub::Hub::start(
            SocketAddr::from(([0, 0, 0, 0], *port)),
            hub::HubConfig { password: cli.password.clone(), host_key: None },
        )
        .await?;
        log!("relay listening on {} (TCP + UDP)", hub.tcp_addr);
        log!("host:   mistria-together host --relay <this machine>:{port}");
        log!("guests: mistria-together join <this machine>:{port}");
        tokio::signal::ctrl_c().await?;
        return Ok(());
    }

    let mode = match &cli.command {
        Some(Command::Host { port, relay }) => Mode::Host { port: *port, relay: relay.clone() },
        Some(Command::Join { addr }) => Mode::Join { addr: addr.clone() },
        Some(Command::Relay { .. }) => unreachable!(),
        None => interactive(&cli)?,
    };

    let ipc_dirs = paths::ipc_dirs(cli.data_dir.as_deref(), cli.instance.as_deref());
    if ipc_dirs.is_empty() {
        bail!("could not work out where Fields of Mistria keeps its data; pass --data-dir");
    }
    if let Some(dir) = &cli.data_dir {
        if !dir.is_dir() {
            bail!("{} is not a directory", dir.display());
        }
    }

    log!("Mistria Together companion {}", env!("CARGO_PKG_VERSION"));
    let companion = match Companion::start(Options { mode: mode.clone(), password: cli.password.clone(), ipc_dirs }).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            if cli.command.is_none() {
                prompt("Press Enter to close.");
            }
            std::process::exit(1);
        }
    };
    match &mode {
        Mode::Host { relay: None, .. } => print_host_addresses(companion.hub_addr.map(|a| a.port()).unwrap_or(DEFAULT_PORT)),
        Mode::Host { relay: Some(addr), .. } => log!("hosting through the relay at {addr}"),
        Mode::Join { addr } => log!("joining {addr}"),
    }
    log!("keep this window open while you play. Ctrl+C to quit.");

    tokio::signal::ctrl_c().await?;
    log!("shutting down");
    companion.stop();
    Ok(())
}

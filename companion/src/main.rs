use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use mistria_together::proto::DEFAULT_PORT;
use mistria_together::{hub, log, paths, Companion, Mode, Options};
use std::io::Write;
use std::net::{SocketAddr, UdpSocket};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "mistria-together",
    version,
    about = "Companion for the Mistria Together co-op mod.\n\nRun it without arguments once to set it up; after that, host and join from the game's Multiplayer menu (F9)."
)]
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
    /// Set everything up: run in the background from now on (no window,
    /// starts when you log in) and hand the mod to MOMI. This is also what
    /// happens when the program is started without arguments.
    Install,
    /// Undo `install`.
    Uninstall,
    /// Run in the background mode `install` sets up: wait for the game and
    /// do what the player picks in its Multiplayer menu.
    Daemon,
    /// Run a standalone relay server. It needs no game: host and guests all
    /// connect to it, so nobody at home has to forward a port.
    Relay {
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
    },
}

fn pause_if_double_clicked() {
    // Started without a terminal of its own (double-click on Windows): keep
    // the window open long enough to read.
    if cfg!(windows) && std::env::var_os("PROMPT").is_none() {
        print!("\nPress Enter to close.");
        let _ = std::io::stdout().flush();
        let _ = std::io::stdin().read_line(&mut String::new());
    }
}

fn run_setup(install: bool) -> ! {
    let result = if install {
        mistria_together::install::install()
    } else {
        mistria_together::install::uninstall()
    };
    let code = match result {
        Ok(lines) => {
            println!("Mistria Together {}\n", env!("CARGO_PKG_VERSION"));
            for line in lines {
                println!("  * {line}");
            }
            0
        }
        Err(e) => {
            eprintln!("Setup failed: {e:#}");
            1
        }
    };
    pause_if_double_clicked();
    std::process::exit(code)
}

/// The local address the OS would use to reach `probe` (no packet is sent).
fn local_addr_towards(probe: &str) -> Option<std::net::IpAddr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect(probe).ok()?;
    socket
        .local_addr()
        .ok()
        .map(|a| a.ip())
        .filter(|ip| !ip.is_unspecified() && !ip.is_loopback())
}

fn print_host_addresses(port: u16) {
    let lan = local_addr_towards("192.0.2.1:9");
    // Tailscale's service address: routes via the tailnet interface if any.
    let tail = local_addr_towards("100.100.100.100:9").filter(|ip| match ip {
        std::net::IpAddr::V4(v4) => v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]),
        _ => false,
    });
    let suffix = if port == DEFAULT_PORT {
        String::new()
    } else {
        format!(":{port}")
    };
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
            hub::HubConfig {
                password: cli.password.clone(),
                host_key: None,
            },
        )
        .await?;
        log!("relay listening on {} (TCP + UDP)", hub.tcp_addr);
        log!("host:   mistria-together host --relay <this machine>:{port}");
        log!("guests: mistria-together join <this machine>:{port}");
        tokio::signal::ctrl_c().await?;
        return Ok(());
    }

    let mode = match &cli.command {
        Some(Command::Host { port, relay }) => Mode::Host {
            port: *port,
            relay: relay.clone(),
        },
        Some(Command::Join { addr }) => Mode::Join { addr: addr.clone() },
        Some(Command::Daemon) => {
            mistria_together::log_to_file(mistria_together::install::log_file());
            Mode::Menu
        }
        Some(Command::Uninstall) => run_setup(false),
        Some(Command::Install) | None => run_setup(true),
        Some(Command::Relay { .. }) => unreachable!(),
    };

    let ipc_dirs = paths::ipc_dirs(cli.data_dir.as_deref(), cli.instance.as_deref());
    if ipc_dirs.is_empty() {
        bail!("could not work out where Fields of Mistria keeps its data; pass --data-dir");
    }
    if let Some(dir) = &cli.data_dir {
        if !dir.is_dir() {
            log!(
                "note: {} does not exist yet - waiting for the game to create it",
                dir.display()
            );
        }
    }

    log!("Mistria Together companion {}", env!("CARGO_PKG_VERSION"));
    let companion = match Companion::start(Options {
        mode: mode.clone(),
        password: cli.password.clone(),
        ipc_dirs,
    })
    .await
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    match &mode {
        Mode::Host { relay: None, .. } => {
            print_host_addresses(companion.hub_addr.map(|a| a.port()).unwrap_or(DEFAULT_PORT))
        }
        Mode::Host {
            relay: Some(addr), ..
        } => log!("hosting through the relay at {addr}"),
        Mode::Join { addr } => log!("joining {addr}"),
        Mode::Menu => log!("waiting for the game; host or join from its Multiplayer menu (F9)"),
    }

    tokio::signal::ctrl_c().await?;
    log!("shutting down");
    companion.stop();
    Ok(())
}

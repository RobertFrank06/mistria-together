//! One-step setup: keep the companion running in the background (started at
//! login, no window) and hand the mod to MOMI.

use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const MOD_ZIP: &str = "MistriaTogether-mod.zip";
#[allow(dead_code)]
const UNIT: &str = "mistria-together.service";
#[allow(dead_code)]
const MAC_LABEL: &str = "io.github.robertfrank06.mistria-together";

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("cannot find your home folder"))
}

/// Where the background copy of the companion lives.
pub fn install_dir() -> Result<PathBuf> {
    if cfg!(windows) {
        let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or_else(|| anyhow!("LOCALAPPDATA is not set"))?;
        Ok(local.join("MistriaTogether"))
    } else if cfg!(target_os = "macos") {
        Ok(home()?.join("Library/Application Support/MistriaTogether"))
    } else {
        let base = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or(home()?.join(".local/share"));
        Ok(base.join("mistria-together"))
    }
}

fn exe_name() -> &'static str {
    if cfg!(windows) {
        "mistria-together.exe"
    } else {
        "mistria-together"
    }
}

pub fn log_file() -> Option<PathBuf> {
    install_dir().ok().map(|d| d.join("companion.log"))
}

fn run(cmd: &mut Command) -> bool {
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
}

/// Folders MOMI reads mods from, most specific first.
fn mods_folders() -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut steam_roots: Vec<PathBuf> = Vec::new();
    if cfg!(windows) {
        for drive in ["C:", "D:", "E:", "F:"] {
            for p in ["Program Files (x86)\\Steam", "Program Files\\Steam", "SteamLibrary", "Steam"] {
                steam_roots.push(PathBuf::from(format!("{drive}\\{p}")));
            }
        }
    } else if let Ok(home) = home() {
        for p in [".local/share/Steam", ".steam/steam", "snap/steam/common/.local/share/Steam", "Library/Application Support/Steam"] {
            steam_roots.push(home.join(p));
        }
    }
    for root in steam_roots {
        let game = root.join("steamapps").join("common").join("Fields of Mistria");
        for name in ["mods", "Mods"] {
            out.push(game.join(name));
        }
    }
    if let Ok(home) = home() {
        out.push(home.join("mistria-mods"));
        out.push(home.join("Mistria-Mods"));
    }
    out.into_iter().filter(|p| p.is_dir()).collect()
}

fn place_mod(report: &mut Vec<String>) {
    let zip = std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.join(MOD_ZIP))).filter(|p| p.is_file());
    let Some(zip) = zip else {
        report.push(format!("The mod archive ({MOD_ZIP}) is not next to this program, so it was not installed. Put it in your MOMI mods folder."));
        return;
    };
    match mods_folders().into_iter().next() {
        Some(folder) => match std::fs::copy(&zip, folder.join(MOD_ZIP)) {
            Ok(_) => report.push(format!("Mod copied to {}. Now open MOMI and press Install.", folder.display())),
            Err(e) => report.push(format!("Could not copy the mod to {}: {e}. Copy {MOD_ZIP} there yourself, then run MOMI.", folder.display())),
        },
        None => report.push(format!(
            "Could not find your MOMI mods folder. Run MOMI once so it creates one, then put {MOD_ZIP} in it and press Install."
        )),
    }
}

fn copy_self(dir: &Path) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let dest = dir.join(exe_name());
    let me = std::env::current_exe()?;
    if me.canonicalize().ok() == dest.canonicalize().ok() {
        return Ok(dest);
    }
    // Write beside and rename, so a running copy is replaced cleanly.
    let tmp = dir.join(format!("{}.new", exe_name()));
    std::fs::copy(&me, &tmp).with_context(|| format!("cannot copy to {}", tmp.display()))?;
    std::fs::rename(&tmp, &dest).with_context(|| format!("cannot replace {}", dest.display()))?;
    Ok(dest)
}

#[cfg(target_os = "linux")]
fn autostart(exe: &Path, enable: bool, report: &mut Vec<String>) -> Result<()> {
    let config = std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or(home()?.join(".config"));
    let unit = config.join("systemd/user").join(UNIT);
    let desktop = config.join("autostart/mistria-together.desktop");
    let has_systemd = run(Command::new("systemctl").args(["--user", "show-environment"]));
    if !enable {
        if has_systemd {
            run(Command::new("systemctl").args(["--user", "disable", "--now", UNIT]));
        }
        let _ = std::fs::remove_file(&unit);
        let _ = std::fs::remove_file(&desktop);
        if has_systemd {
            run(Command::new("systemctl").args(["--user", "daemon-reload"]));
        } else {
            run(Command::new("pkill").args(["-f", "[m]istria-together daemon"]));
        }
        return Ok(());
    }
    if has_systemd {
        std::fs::create_dir_all(unit.parent().unwrap())?;
        std::fs::write(
            &unit,
            format!(
                "[Unit]\nDescription=Mistria Together companion (co-op for Fields of Mistria)\n\n[Service]\nExecStart=\"{}\" daemon\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n",
                exe.display()
            ),
        )?;
        run(Command::new("systemctl").args(["--user", "daemon-reload"]));
        if !run(Command::new("systemctl").args(["--user", "enable", UNIT])) || !run(Command::new("systemctl").args(["--user", "restart", UNIT])) {
            return Err(anyhow!("systemctl could not start the service (try: systemctl --user status {UNIT})"));
        }
        report.push("Companion is running in the background and starts with your session (systemd user service).".into());
    } else {
        std::fs::create_dir_all(desktop.parent().unwrap())?;
        std::fs::write(
            &desktop,
            format!("[Desktop Entry]\nType=Application\nName=Mistria Together companion\nExec=\"{}\" daemon\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n", exe.display()),
        )?;
        run(Command::new("pkill").args(["-f", "[m]istria-together daemon"]));
        Command::new(exe).arg("daemon").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?;
        report.push("Companion is running in the background and starts when you log in.".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn autostart(exe: &Path, enable: bool, report: &mut Vec<String>) -> Result<()> {
    let plist = home()?.join("Library/LaunchAgents").join(format!("{MAC_LABEL}.plist"));
    run(Command::new("launchctl").arg("unload").arg(&plist));
    if !enable {
        let _ = std::fs::remove_file(&plist);
        return Ok(());
    }
    std::fs::create_dir_all(plist.parent().unwrap())?;
    std::fs::write(
        &plist,
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n<key>Label</key><string>{MAC_LABEL}</string>\n<key>ProgramArguments</key><array><string>{}</string><string>daemon</string></array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n</dict></plist>\n",
            exe.display()
        ),
    )?;
    if !run(Command::new("launchctl").arg("load").arg(&plist)) {
        return Err(anyhow!("launchctl could not load {}", plist.display()));
    }
    report.push("Companion is running in the background and starts when you log in.".into());
    Ok(())
}

#[cfg(windows)]
fn autostart(exe: &Path, enable: bool, report: &mut Vec<String>) -> Result<()> {
    const RUN_KEY: &str = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    let dir = exe.parent().unwrap();
    let vbs = dir.join("start-hidden.vbs");
    // Stop a copy that is already running (but not this process).
    run(Command::new("taskkill").args(["/F", "/IM", exe_name(), "/FI", &format!("PID ne {}", std::process::id())]));
    if !enable {
        run(Command::new("reg").args(["delete", RUN_KEY, "/v", "MistriaTogether", "/f"]));
        let _ = std::fs::remove_file(&vbs);
        return Ok(());
    }
    // Window style 0 = hidden: the companion never shows a console.
    std::fs::write(&vbs, format!("CreateObject(\"WScript.Shell\").Run \"\"\"{}\"\" daemon\", 0, False\r\n", exe.display()))?;
    let value = format!("wscript.exe \"{}\"", vbs.display());
    if !run(Command::new("reg").args(["add", RUN_KEY, "/v", "MistriaTogether", "/t", "REG_SZ", "/d", &value, "/f"])) {
        return Err(anyhow!("could not register the companion to start with Windows"));
    }
    if !run(Command::new("wscript.exe").arg(&vbs)) {
        return Err(anyhow!("could not start the companion in the background"));
    }
    report.push("Companion is running in the background and starts with Windows (no window).".into());
    report.push("The first time you host, Windows Firewall will ask to allow it: say yes.".into());
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn autostart(_exe: &Path, _enable: bool, _report: &mut Vec<String>) -> Result<()> {
    Err(anyhow!("background start is not supported on this system; run `mistria-together daemon` yourself"))
}

/// Install the background companion and place the mod. Returns lines to show.
pub fn install() -> Result<Vec<String>> {
    let mut report = Vec::new();
    let dir = install_dir()?;
    #[cfg(windows)]
    {
        // A running copy keeps its file locked on Windows.
        run(Command::new("taskkill").args(["/F", "/IM", exe_name(), "/FI", &format!("PID ne {}", std::process::id())]));
        std::thread::sleep(std::time::Duration::from_millis(400));
    }
    let exe = copy_self(&dir)?;
    autostart(&exe, true, &mut report)?;
    place_mod(&mut report);
    report.push("In the game: press F9 (or use Multiplayer on the title screen) to host or join.".into());
    Ok(report)
}

pub fn uninstall() -> Result<Vec<String>> {
    let mut report = Vec::new();
    let dir = install_dir()?;
    autostart(&dir.join(exe_name()), false, &mut report)?;
    let _ = std::fs::remove_dir_all(&dir);
    report.push("Background companion removed.".into());
    report.push(format!("To remove the mod too, delete {MOD_ZIP} from your MOMI mods folder and run MOMI."));
    Ok(report)
}

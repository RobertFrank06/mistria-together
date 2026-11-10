//! One-step setup: keep the companion running in the background (started at
//! login, no window) and hand the mod to MOMI.

use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const MOD_DIR: &str = "mt";
const MOD_MANIFEST_NAME: &str = "name = \"Mistria Together\"";
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
        let local = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("LOCALAPPDATA is not set"))?;
        Ok(local.join("MistriaTogether"))
    } else if cfg!(target_os = "macos") {
        Ok(home()?.join("Library/Application Support/MistriaTogether"))
    } else {
        let base = std::env::var_os("XDG_DATA_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or(home()?.join(".local/share"));
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
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Folders MOMI reads mods from, most specific first.
fn mods_folders() -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut steam_roots: Vec<PathBuf> = Vec::new();
    if cfg!(windows) {
        for drive in ["C:", "D:", "E:", "F:"] {
            for p in [
                "Program Files (x86)\\Steam",
                "Program Files\\Steam",
                "SteamLibrary",
                "Steam",
            ] {
                steam_roots.push(PathBuf::from(format!("{drive}\\{p}")));
            }
        }
    } else if let Ok(home) = home() {
        for p in [
            ".local/share/Steam",
            ".steam/steam",
            "snap/steam/common/.local/share/Steam",
            "Library/Application Support/Steam",
        ] {
            steam_roots.push(home.join(p));
        }
    }
    for root in steam_roots {
        let game = root
            .join("steamapps")
            .join("common")
            .join("Fields of Mistria");
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

fn install_mod_dir(source: &Path, mods: &Path) -> Result<()> {
    let manifest = source.join("manifest.toml");
    let manifest_text = std::fs::read_to_string(&manifest)
        .with_context(|| format!("missing bundled mod manifest at {}", manifest.display()))?;
    if !manifest_text.contains(MOD_MANIFEST_NAME) {
        return Err(anyhow!(
            "bundled mod manifest does not identify Mistria Together"
        ));
    }
    std::fs::create_dir_all(mods)?;
    let dest = mods.join(MOD_DIR);
    if dest.exists() {
        let old_manifest = std::fs::read_to_string(dest.join("manifest.toml"))
            .with_context(|| format!("refusing to replace unrelated folder {}", dest.display()))?;
        if !old_manifest.contains(MOD_MANIFEST_NAME) {
            return Err(anyhow!(
                "refusing to replace unrelated folder {}",
                dest.display()
            ));
        }
    }
    let stage = mods.join(".mt-staging");
    let backup = mods.join(".mt-previous");
    if stage.exists() {
        std::fs::remove_dir_all(&stage)?;
    }
    copy_tree(source, &stage)?;
    if backup.exists() {
        std::fs::remove_dir_all(&backup)?;
    }
    if dest.exists() {
        std::fs::rename(&dest, &backup)?;
    }
    if let Err(error) = std::fs::rename(&stage, &dest) {
        if backup.exists() {
            let _ = std::fs::rename(&backup, &dest);
        }
        return Err(error.into());
    }
    if backup.exists() {
        std::fs::remove_dir_all(backup)?;
    }
    Ok(())
}

fn copy_tree(source: &Path, dest: &Path) -> Result<()> {
    std::fs::create_dir_all(dest)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let path = entry.path();
        let target = dest.join(entry.file_name());
        if path.is_dir() {
            copy_tree(&path, &target)?;
        } else {
            std::fs::copy(path, target)?;
        }
    }
    Ok(())
}

fn place_mod(report: &mut Vec<String>) {
    let source = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|p| p.join(MOD_DIR)))
        .filter(|p| p.is_dir());
    let Some(source) = source else {
        report.push("The extracted mod folder (mt) is not next to this program. Re-extract the complete release package.".into());
        return;
    };
    match mods_folders().into_iter().next() {
        Some(folder) => match install_mod_dir(&source, &folder) {
            Ok(()) => report.push(format!("Extracted mod installed to {}. Open MOMI and press Install.", folder.display())),
            Err(e) => report.push(format!("Could not install the mod to {}: {e}. Copy the extracted mt folder there and run MOMI.", folder.display())),
        },
        None => report.push(
            "Could not find your MOMI mods folder. Run MOMI once so it creates one, then copy the extracted mt folder there and press Install.".into(),
        ),
    }
}

fn copy_self(dir: &Path) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let dest = dir.join(exe_name());
    let me = std::env::current_exe()?;
    if me.canonicalize().ok() == dest.canonicalize().ok() {
        return Ok(dest);
    }
    // Stage beside the destination. On Windows rename cannot replace an
    // existing destination, so move it aside and restore it on failure.
    let tmp = dir.join(format!("{}.new", exe_name()));
    let old = dir.join(format!("{}.old", exe_name()));
    std::fs::copy(&me, &tmp).with_context(|| format!("cannot copy to {}", tmp.display()))?;
    if old.exists() {
        std::fs::remove_file(&old)?;
    }
    if dest.exists() {
        std::fs::rename(&dest, &old)
            .with_context(|| format!("cannot stage old executable {}", dest.display()))?;
    }
    if let Err(error) = std::fs::rename(&tmp, &dest) {
        if old.exists() {
            let _ = std::fs::rename(&old, &dest);
        }
        let _ = std::fs::remove_file(&tmp);
        return Err(error).with_context(|| format!("cannot replace {}", dest.display()));
    }
    if old.exists() {
        std::fs::remove_file(old)?;
    }
    Ok(dest)
}

#[cfg(target_os = "linux")]
fn autostart(exe: &Path, enable: bool, report: &mut Vec<String>) -> Result<()> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or(home()?.join(".config"));
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
        if !run(Command::new("systemctl").args(["--user", "enable", UNIT]))
            || !run(Command::new("systemctl").args(["--user", "restart", UNIT]))
        {
            return Err(anyhow!(
                "systemctl could not start the service (try: systemctl --user status {UNIT})"
            ));
        }
        report.push("Companion is running in the background and starts with your session (systemd user service).".into());
    } else {
        std::fs::create_dir_all(desktop.parent().unwrap())?;
        std::fs::write(
            &desktop,
            format!("[Desktop Entry]\nType=Application\nName=Mistria Together companion\nExec=\"{}\" daemon\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n", exe.display()),
        )?;
        run(Command::new("pkill").args(["-f", "[m]istria-together daemon"]));
        Command::new(exe)
            .arg("daemon")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        report.push("Companion is running in the background and starts when you log in.".into());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn autostart(exe: &Path, enable: bool, report: &mut Vec<String>) -> Result<()> {
    let plist = home()?
        .join("Library/LaunchAgents")
        .join(format!("{MAC_LABEL}.plist"));
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
    run(Command::new("taskkill").args([
        "/F",
        "/IM",
        exe_name(),
        "/FI",
        &format!("PID ne {}", std::process::id()),
    ]));
    if !enable {
        run(Command::new("reg").args(["delete", RUN_KEY, "/v", "MistriaTogether", "/f"]));
        let _ = std::fs::remove_file(&vbs);
        return Ok(());
    }
    // Window style 0 = hidden: the companion never shows a console.
    std::fs::write(
        &vbs,
        format!(
            "CreateObject(\"WScript.Shell\").Run \"\"\"{}\"\" daemon\", 0, False\r\n",
            exe.display()
        ),
    )?;
    let value = format!("wscript.exe \"{}\"", vbs.display());
    if !run(Command::new("reg").args([
        "add",
        RUN_KEY,
        "/v",
        "MistriaTogether",
        "/t",
        "REG_SZ",
        "/d",
        &value,
        "/f",
    ])) {
        return Err(anyhow!(
            "could not register the companion to start with Windows"
        ));
    }
    if !run(Command::new("wscript.exe").arg(&vbs)) {
        return Err(anyhow!("could not start the companion in the background"));
    }
    report
        .push("Companion is running in the background and starts with Windows (no window).".into());
    report.push("The first time you host, Windows Firewall will ask to allow it: say yes.".into());
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn autostart(_exe: &Path, _enable: bool, _report: &mut Vec<String>) -> Result<()> {
    Err(anyhow!(
        "background start is not supported on this system; run `mistria-together daemon` yourself"
    ))
}

/// Install the background companion and place the mod. Returns lines to show.
pub fn install() -> Result<Vec<String>> {
    let mut report = Vec::new();
    let dir = install_dir()?;
    #[cfg(windows)]
    {
        // A running copy keeps its file locked on Windows.
        run(Command::new("taskkill").args([
            "/F",
            "/IM",
            exe_name(),
            "/FI",
            &format!("PID ne {}", std::process::id()),
        ]));
        std::thread::sleep(std::time::Duration::from_millis(400));
    }
    let exe = copy_self(&dir)?;
    autostart(&exe, true, &mut report)?;
    place_mod(&mut report);
    report.push(
        "In the game: press F9 (or use Multiplayer on the title screen) to host or join.".into(),
    );
    Ok(report)
}

pub fn uninstall() -> Result<Vec<String>> {
    let mut report = Vec::new();
    let dir = install_dir()?;
    autostart(&dir.join(exe_name()), false, &mut report)?;
    let _ = std::fs::remove_dir_all(&dir);
    report.push("Background companion removed.".into());
    report.push(
        "To remove the mod too, delete the mt folder from your MOMI mods folder and run MOMI."
            .into(),
    );
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mod_tree(root: &Path, name: &str, content: &str) -> PathBuf {
        let path = root.join(name);
        std::fs::create_dir_all(path.join("gml")).unwrap();
        std::fs::write(path.join("manifest.toml"), content).unwrap();
        std::fs::write(path.join("gml/main.gml"), "source").unwrap();
        path
    }

    #[test]
    fn installs_extracted_tree_and_replaces_own_version() {
        let temp = tempfile::tempdir().unwrap();
        let source = mod_tree(temp.path(), "bundle", MOD_MANIFEST_NAME);
        let mods = temp.path().join("mods");
        install_mod_dir(&source, &mods).unwrap();
        assert_eq!(
            std::fs::read_to_string(mods.join("mt/gml/main.gml")).unwrap(),
            "source"
        );
        std::fs::write(mods.join("mt/old.txt"), "old").unwrap();
        install_mod_dir(&source, &mods).unwrap();
        assert!(!mods.join("mt/old.txt").exists());
    }

    #[test]
    fn refuses_to_replace_unrelated_folder() {
        let temp = tempfile::tempdir().unwrap();
        let source = mod_tree(temp.path(), "bundle", MOD_MANIFEST_NAME);
        let mods = temp.path().join("mods");
        mod_tree(&mods, "mt", "name = \"Another Mod\"");
        assert!(install_mod_dir(&source, &mods).is_err());
        assert_eq!(
            std::fs::read_to_string(mods.join("mt/manifest.toml")).unwrap(),
            "name = \"Another Mod\""
        );
    }

    #[test]
    fn invalid_source_does_not_remove_existing_install() {
        let temp = tempfile::tempdir().unwrap();
        let mods = temp.path().join("mods");
        let old = mod_tree(&mods, "mt", MOD_MANIFEST_NAME);
        std::fs::write(old.join("gml/main.gml"), "previous").unwrap();
        let bad_source = temp.path().join("bad");
        std::fs::create_dir_all(&bad_source).unwrap();
        assert!(install_mod_dir(&bad_source, &mods).is_err());
        assert_eq!(
            std::fs::read_to_string(mods.join("mt/gml/main.gml")).unwrap(),
            "previous"
        );
    }
}

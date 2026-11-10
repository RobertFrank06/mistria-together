//! Finding the game's save-data directory, which is where the mod and the
//! companion exchange files.

use std::path::{Path, PathBuf};

pub const MOD_NAME: &str = "mistria_together";
const GAME_DIR: &str = "FieldsOfMistria";
const STEAM_APP_ID: &str = "2142790";

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// Every place the game might keep its data on this machine, most likely
/// first. Not all of them exist.
pub fn data_dir_candidates() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    let home = env_path("HOME").or_else(|| env_path("USERPROFILE"));

    if cfg!(windows) {
        if let Some(local) = env_path("LOCALAPPDATA") {
            roots.push(local.join(GAME_DIR));
        }
    } else if cfg!(target_os = "macos") {
        if let Some(home) = &home {
            roots.push(home.join("Library/Application Support").join(GAME_DIR));
        }
    } else {
        // Native Linux build.
        if let Some(xdg) = env_path("XDG_DATA_HOME") {
            roots.push(xdg.join(GAME_DIR));
        }
        if let Some(home) = &home {
            roots.push(home.join(".local/share").join(GAME_DIR));
            // Windows build under Proton.
            for steam in [
                ".local/share/Steam",
                ".steam/steam",
                ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ] {
                roots.push(
                    home.join(steam)
                        .join("steamapps/compatdata")
                        .join(STEAM_APP_ID)
                        .join("pfx/drive_c/users/steamuser/AppData/Local")
                        .join(GAME_DIR),
                );
            }
        }
    }

    // Beta branches keep their data one level down (FieldsOfMistria/beta/...).
    let mut out = Vec::new();
    for root in roots {
        if out.contains(&root) {
            continue;
        }
        if let Ok(entries) = std::fs::read_dir(&root) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && path.join("saves").is_dir() {
                    out.push(path);
                }
            }
        }
        out.push(root);
    }
    out
}

/// The ipc directory inside a game data directory.
pub fn ipc_dir(data_dir: &Path, instance: Option<&str>) -> PathBuf {
    let name = match instance {
        Some(i) if !i.is_empty() => format!("ipc_{i}"),
        _ => "ipc".to_string(),
    };
    data_dir.join("mod_data").join(MOD_NAME).join(name)
}

/// The ipc directories to watch: the explicit one, or all candidates.
pub fn ipc_dirs(explicit: Option<&Path>, instance: Option<&str>) -> Vec<PathBuf> {
    match explicit {
        Some(dir) => vec![ipc_dir(dir, instance)],
        None => data_dir_candidates()
            .iter()
            .map(|d| ipc_dir(d, instance))
            .collect(),
    }
}

/// Where the companion remembers the last host/join choice.
pub fn settings_file(explicit: Option<&Path>) -> Option<PathBuf> {
    let dir = match explicit {
        Some(d) => Some(d.to_path_buf()),
        None => data_dir_candidates().into_iter().find(|d| d.is_dir()),
    }?;
    Some(dir.join("mod_data").join(MOD_NAME).join("companion.json"))
}

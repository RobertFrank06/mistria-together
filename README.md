# Mistria Together

Co-op multiplayer for [Fields of Mistria](https://www.fieldsofmistria.com/): play on one farm with your friends.

It has two parts:

- **the mod** (`mod/mt`, plain GML, installed with [MOMI](https://github.com/Garethp/Mods-of-Mistria-Installer)), which runs inside the game, and
- **the companion** (`companion/`, Rust), a small program you run next to the game. The game's scripting runtime cannot open network connections, so the companion does all the networking and talks to the mod through files in the game's save folder.

> Unofficial fan project, not affiliated with NPC Studio. Early software: back up your saves.
> Developed and play-tested on Linux (native build). CI builds and tests the Windows and macOS companions, but those builds have not yet been play-tested in game.

## What works

| | |
| --- | --- |
| Seeing each other | Other players appear as their own character: appearance, clothes, animations, tools and held items, name tag. Up to 8 players. |
| Smooth movement | Movement is sent 20 times a second over UDP and played back on a short, adaptive delay with interpolation, so players glide instead of teleporting. A lost packet is simply replaced by the next one. |
| One shared farm | Guests load the host's world when they join and again every morning. In between, changes are shared live in both directions: objects placed, removed or damaged (trees, rocks, crops, furniture, chests and their contents), soil tilled and watered. Changes made while you are somewhere else are waiting when you come back. |
| Shared time | The host's clock, calendar and weather are everyone's. Pausing on the host pauses time for all. |
| Staying connected | The game keeps running when its window loses focus. Guests reconnect by themselves if the host restarts or the connection drops. |
| Saved friends | Save a display label and hostname/IP once, then reconnect from the in-game Friends list. The label is chosen by you; it is not linked to Steam automatically. |
| Low overhead | About 0.2-0.4 ms of a 16 ms frame in testing. No full-world scans, no rewriting one shared file. |

## What does not (yet)

- Each player keeps their own inventory, money, skills, relationships and story progress. Items dropped on the ground are only visible to the player who dropped them (put things in a chest to hand them over).
- Dungeon floors are generated per player and are not shared; you will not see each other in the mines.
- Mounts and pets of other players are not drawn. NPCs and farm animals are simulated by each game on its own and can stand in different places for different players.
- Buildings placed during a day reach the other players with the next morning's snapshot.
- **Stardew-style group sleep is not implemented yet.** Currently the host's day transition drives guests forward; guests cannot mark themselves ready for bed and hold the group until everyone is ready. See [DESIGN.md](DESIGN.md) for the intended co-op model.
- Traffic is not encrypted. Use a VPN such as Tailscale (recommended anyway, it needs no port forwarding), or a session password on a network you trust.

## Install

Everyone who plays needs both parts, in the same version.

Everyone needs the same release of both the mod and companion.

1. Install [MOMI](https://github.com/Garethp/Mods-of-Mistria-Installer/releases) 0.17.0 or newer and run it once so it creates its mods folder.
2. Download the companion package for your system from the [releases page](https://github.com/RobertFrank06/mistria-together/releases): `MistriaTogether-windows.zip`, `MistriaTogether-linux.tar.gz`, or `MistriaTogether-macos.tar.gz`.
3. Extract the complete package and run `mistria-together` (Windows: `mistria-together.exe`) once. It installs a background companion and copies the extracted `mt` folder into the MOMI mods folder. If it cannot find the folder, copy the package's `mt` folder into MOMI's mods folder yourself.
4. Open MOMI and press Install. MOMI needs the extracted folder with `manifest.toml` directly inside `mt`; the optional ZIP is for manual distribution only. Remove any other multiplayer mod first.

To undo the companion setup, run `mistria-together uninstall` from a terminal. This removes its background startup and installed companion; remove the mod through MOMI separately.

## Play

1. Start Fields of Mistria. The helper runs in the background after setup.
2. Choose **Multiplayer** on the title screen, or press `F9` while playing. The title screen button is also available when starting a save directly.
3. The host chooses **Host**. Friends on the same local network can find the session under **Nearby**. For internet play, use a VPN or relay; add the host's hostname/IP under **Friends** once. DNS names work when the VPN or network resolves them.
4. Guests choose **Join**, select a discovered local session or enter an address, then load a save. The order does not matter; joining begins when the guest loads into the world.
5. The in-game status and player list appear in the top-left corner. Press `F9` to hide or show the HUD. **Settings** controls local HUD/name-tag display, movement smoothing, and the session password. Open Multiplayer again to see the session status or disconnect.

For internet play without a VPN or relay, the host must forward TCP and UDP port 7777 on their router and share their public address. The companion's terminal mode prints local and Tailscale addresses; the in-game menu mode runs quietly in the background.

The host owns the shared farm, time, weather, upgrades and decor. A guest's game adopts that world snapshot, while the guest keeps their own inventory, money, skills, relationships and story progress. The guest's original save is backed up under `mod_data/mistria_together/backups/` before the first host snapshot; that first backup is preserved across reconnects. Do not treat the backup as a save merge tool.

### Command line

```text
mistria-together host [--port 7777] [--password PW]
mistria-together join <address[:port]> [--password PW]
mistria-together relay [--port 7777] [--password PW]
mistria-together host --relay <address[:port]>
mistria-together uninstall
```

The default install is the in-game menu with an always-running companion. The `host` and `join` commands are optional ways to choose the session from a terminal instead. `relay` runs a standalone session server that needs no game. Put it on any machine both players can reach (a small VPS is enough): the host runs `host --relay <server>`, guests run `join <server>`, and nobody has to forward a port at home.

Other options: `--data-dir <folder>` if the game's data folder is not found automatically, and `--instance <name>` together with the environment variable `MISTRIA_TOGETHER_INSTANCE=<name>` on the game, to run two games on one machine.

### Settings

`mod_data/mistria_together/mistria_together.json` in the game's data folder (`%LOCALAPPDATA%\FieldsOfMistria` on Windows, `~/.local/share/FieldsOfMistria` on Linux) is created on first run:

| Key | Default | |
| --- | --- | --- |
| `show_hud` | `true` | Status and player list in the corner. |
| `menu_key` | `"F9"` | Key that opens Multiplayer. |
| `name_tags` | `true` | Names above other players. |
| `smoothing_frames` | `7` | How far behind real time others are drawn (60 = one second). Raise it on a rough connection. |
| `send_interval` | `3` | Frames between movement updates. |
| `no_focus_pause` | `true` | Do not pause when the window loses focus while online. |
| `sync_world` | `true` | As a guest, load the host's farm, time and weather. |

### Troubleshooting

- **"companion not running" in game:** start `mistria-together`. If it runs but says *waiting for the game*, it is looking in the wrong place: pass `--data-dir`.
- **Guest cannot connect:** the host's port 7777 must be reachable over TCP and UDP. Tailscale avoids the question entirely. If only UDP is blocked the session still works, movement just rides on TCP.
- **"mod version mismatch":** everyone needs the same release of both parts.
- Logs: the companion's window, and `mod_data/mistria_together/logs/mistria_together.log`.

## How it works

See [DESIGN.md](DESIGN.md) for the architecture and save-ownership boundaries.

```text
 game (GML mod)  <-- files -->  companion  <== TCP + UDP ==>  hub  <==>  other companions  <-- files -->  their game
```

- **File bridge** (`mod/mt/gml/MtIpc.gml`, `companion/src/bridge.rs`). Both sides exchange numbered JSON batches in the game's data folder, first writing to a temporary file and then renaming it into place. The mod also sends menu choices through a control file; the companion reports session status and LAN discoveries back to the game. Sequence numbers let both sides read messages in order without sharing or partially reading a file.
- **Hub** (`companion/src/hub.rs`). The host's companion runs a small session server in-process; `relay` runs the same server standalone. Reliable traffic goes over TCP. Movement goes over UDP with automatic TCP fallback per player.
- **Local discovery** (`companion/src/lan.rs`). Hosts periodically broadcast a small UDP beacon on the local network. Other companions show those sessions in the in-game join menu. Beacons do not cross the internet or VPNs, so remote friends enter an address once.
- **Players** (`MtPlayers.gml`). Poses carry the sender's frame number; the receiver interpolates on that timeline and bends its playback speed slightly to hold a constant delay.
- **World** (`MtSync.gml`). Snapshots use the game's own save serializer and loader, shipped through the companion as a compressed file. Live changes are found by comparing the grid you stand in with a private copy, a slice per frame, densest around the player.

## Building and testing

```bash
cargo test                      # companion: unit tests + real-socket, real-file session tests
cargo build --release           # target/release/mistria-together
tools/package-mod.sh            # dist/MistriaTogether-mod.zip
```

`tools/rig.sh` and `tools/e2e.sh` (Linux) set up an isolated copy of the game with its own save folder and run two real instances headless under gamescope against each other; `MISTRIA_TOGETHER_DEV` turns on the mod's test hooks (`mod/mt/gml/MtDev.gml`). The rig never touches your real install or saves.

Pushing a version tag runs tests and builds release packages for Linux, Windows and macOS. Each package contains the companion, the extracted MOMI mod folder, a convenience mod ZIP, license, and a short first-run guide.

## License

GPL-3.0-or-later. The mod builds on [MMAPI](https://github.com/Garethp/Mods-of-Mistria-Installer), which is GPL-3.0-or-later.

# Mistria Together

Co-op multiplayer for [Fields of Mistria](https://www.fieldsofmistria.com/): play on one farm with your friends.

It has two parts:

- **the mod** (`mod/mt`, plain GML, installed with [MOMI](https://github.com/Garethp/Mods-of-Mistria-Installer)), which runs inside the game, and
- **the companion** (`companion/`, Rust), a small program you run next to the game. The game's scripting runtime cannot open network connections, so the companion does all the networking and talks to the mod through files in the game's save folder.

> Unofficial fan project, not affiliated with NPC Studio. Early software: back up your saves.
> Developed and play-tested on Linux (native build). The Windows and macOS companions are built and unit-tested by CI but have not been play-tested yet.

## What works

| | |
| --- | --- |
| Seeing each other | Other players appear as their own character: appearance, clothes, animations, tools and held items, name tag. Up to 8 players. |
| Smooth movement | Movement is sent 20 times a second over UDP and played back on a short, adaptive delay with interpolation, so players glide instead of teleporting. A lost packet is simply replaced by the next one. |
| One shared farm | Guests load the host's world when they join and again every morning. In between, changes are shared live in both directions: objects placed, removed or damaged (trees, rocks, crops, furniture, chests and their contents), soil tilled and watered. Changes made while you are somewhere else are waiting when you come back. |
| Shared time | The host's clock, calendar and weather are everyone's. Pausing on the host pauses time for all. |
| Staying connected | The game keeps running when its window loses focus. Guests reconnect by themselves if the host restarts or the connection drops. |
| Low overhead | About 0.2-0.4 ms of a 16 ms frame in testing. No full-world scans, no rewriting one shared file. |

## What does not (yet)

- Each player keeps their own inventory, money, skills, relationships and story progress. Items dropped on the ground are only visible to the player who dropped them (put things in a chest to hand them over).
- Dungeon floors are generated per player and are not shared; you will not see each other in the mines.
- Mounts and pets of other players are not drawn. NPCs and farm animals are simulated by each game on its own and can stand in different places for different players.
- Buildings placed during a day reach the other players with the next morning's snapshot.
- The day ends when the **host** sleeps. A guest who goes to bed alone is put back in step with the host.
- Traffic is not encrypted. Use a VPN such as Tailscale (recommended anyway, it needs no port forwarding), or a session password on a network you trust.

## Install

Everyone who plays needs both parts, in the same version.

1. Install [MOMI](https://github.com/Garethp/Mods-of-Mistria-Installer/releases) 0.17.0 or newer.
2. Download `MistriaTogether-mod.zip` from the [releases page](https://github.com/RobertFrank06/mistria-together/releases) and put it, still zipped, in your MOMI mods folder. Remove any other multiplayer mod.
3. Run MOMI and install.
4. Download the companion for your system from the same release (`mistria-together-windows-x86_64.zip`, `…-linux-x86_64.tar.gz`, `…-macos-arm64.tar.gz`) and unpack it anywhere.

## Play

1. Everyone starts the companion (`mistria-together`, or double-click `mistria-together.exe`) and picks **Host** or **Join**. Guests type the host's address; it is remembered for next time.
2. Everyone starts Fields of Mistria and loads a save. The order does not matter.
3. The top-left corner of the screen shows the connection status and who is online. `F9` hides it.

The host's window prints the addresses guests can use:

```text
[10:16:54] hosting on port 7777 (TCP + UDP). Other players run:
[10:16:54]     mistria-together join 100.76.202.16      (Tailscale)
[10:16:54]     mistria-together join 192.168.178.24     (same network)
```

Guests should join with a character they do not mind sharing a world with: while connected, a guest's game holds the *host's* farm, and saving stores that. The mod copies the guest's save to `mod_data/mistria_together/backups/` in the game's data folder the first time it loads a host's world.

### Command line

```text
mistria-together host [--port 7777] [--password PW]
mistria-together join <address[:port]> [--password PW]
mistria-together relay [--port 7777] [--password PW]
mistria-together host --relay <address[:port]>
```

`relay` runs a standalone session server that needs no game. Put it on any machine both players can reach (a cheap VPS is plenty): the host runs `host --relay <server>`, guests run `join <server>`, and nobody has to forward a port at home.

Other options: `--data-dir <folder>` if the game's data folder is not found automatically, and `--instance <name>` together with the environment variable `MISTRIA_TOGETHER_INSTANCE=<name>` on the game, to run two games on one machine.

### Settings

`mod_data/mistria_together/mistria_together.json` in the game's data folder (`%LOCALAPPDATA%\FieldsOfMistria` on Windows, `~/.local/share/FieldsOfMistria` on Linux) is created on first run:

| Key | Default | |
| --- | --- | --- |
| `show_hud` | `true` | Status and player list in the corner. |
| `hud_key` | `"F9"` | Key that toggles it. |
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

```text
 game (GML mod)  <-- files -->  companion  <== TCP + UDP ==>  hub  <==>  other companions  <-- files -->  their game
```

- **File bridge** (`mod/mt/gml/MtIpc.gml`, `companion/src/bridge.rs`). Both sides write numbered JSON batches into the save folder, each under a temporary name and then renamed into place, and read them strictly in order. No file is ever shared, rewritten or half-read, which is what makes the bridge reliable on Windows too.
- **Hub** (`companion/src/hub.rs`). The host's companion runs a small session server in-process; `relay` runs the same server standalone. Reliable traffic goes over TCP. Movement goes over UDP with automatic TCP fallback per player.
- **Players** (`MtPlayers.gml`). Poses carry the sender's frame number; the receiver interpolates on that timeline and bends its playback speed slightly to hold a constant delay.
- **World** (`MtSync.gml`). Snapshots use the game's own save serializer and loader, shipped through the companion as a compressed file. Live changes are found by comparing the grid you stand in with a private copy, a slice per frame, densest around the player.

## Building and testing

```bash
cargo test                      # companion: unit tests + real-socket, real-file session tests
cargo build --release           # target/release/mistria-together
tools/package-mod.sh            # dist/MistriaTogether-mod.zip
```

`tools/rig.sh` and `tools/e2e.sh` (Linux) set up an isolated copy of the game with its own save folder and run two real instances headless under gamescope against each other; `MISTRIA_TOGETHER_DEV` turns on the mod's test hooks (`mod/mt/gml/MtDev.gml`). The rig never touches your real install or saves.

Pushing a tag `v*` builds the release archives for Linux, Windows and macOS.

## License

GPL-3.0-or-later. The mod builds on [MMAPI](https://github.com/Garethp/Mods-of-Mistria-Installer), which is GPL-3.0-or-later.

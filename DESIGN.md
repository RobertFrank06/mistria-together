# Mistria Together Design

Mistria Together aims to bring the core Stardew Valley co-op experience to
Fields of Mistria: one persistent farm played together, with a host-owned world,
individual farmers, and group decisions that move the day forward. This is the
target design; the current mod is an early step toward it.

## Target multiplayer model

- The host owns and saves the persistent co-op farm. The host must open it for
  others to play; guests cannot use that farm or its farmhand characters while
  the host is offline. Each farmhand has a persistent character slot on that
  farm, separate from the player's solo save.
- Everyone shares the farm and its world state. Character-owned inventory,
  skills, relationships, and personal quests remain individual. Farm, town,
  mine, and museum unlocks should be shared when Mistria confirms they are
  global progress.
- The group advances the day together. A player going to bed means “ready for
  the night,” not “advance now.” The next day starts after everyone is ready
  (or has passed out), everyone resolves the overnight summary, and shared
  choices are settled. The host remains authoritative for applying and saving
  that transition.
- The host controls session-wide rules and can pause the shared game. A
  player's menu or inventory should not silently pause or advance everyone
  else's world.
- Money should support a host-selected shared or separate mode, like Stardew.
  Implement it only after Mistria's money ownership and safe transfer behavior
  are verified; don't merge wallets by copying whole saves.

Stardew is a reference for these co-op principles, not a claim that every
Mistria system must behave identically. In Stardew, the host owns the save and
must load the farm; all players confirm sleep before the day ends, then dismiss
the overnight earnings screen; the host can pause time for everyone; wallets
can be shared or separate; and farm/world unlocks are shared while skills,
relationships, and most quests are personal. Sources: ConcernedApe's
[multiplayer FAQ](https://store.steampowered.com/news/posts/?appgroupname=Stardew+Valley&appids=413150&enddate=1551465789&feed=steam_community_announcements),
[1.4 changelog](https://www.stardewvalley.net/stardew-valley-1-4-update-full-changelog/),
and the current [multiplayer overview](https://stardewvalleywiki.com/Multiplayer)
and [day-cycle rules](https://stardewvalleywiki.com/Day_Cycle).

## Multiplayer menu direction

The title screen should place **Multiplayer** in the game's normal vertical
button list, immediately after **New Game**. Selecting it opens a Mistria-styled
menu with **Join**, **Host**, and **Settings** choices. Keep the in-game `F9`
shortcut for session status and disconnect.

The Join flow should offer nearby games, saved friends, adding a friend, and
direct joining by hostname or IP address. Saved friend names are local labels,
not verified Steam identities. The host flow explains that hosting begins when
the host loads a save. Joining still begins when a guest loads a local save;
persistent farmhand saves are future work.

Use Mistria's own menu-button visuals and vertical input-pilot navigation. Keep
long nearby/friend lists navigable without letting them overflow the screen.
Settings retain the existing local HUD/name-tag, movement smoothing, and
session-password controls.

Approaches considered: a chain of ordinary popups would reuse more current
code, but it would make the choice hierarchy and longer friend lists awkward.
A dedicated Mistria-styled menu flow is selected because it gives players the
clear Join/Host/Settings entry and room to browse friends. This is a menu
reorganization; it does not change save ownership or synchronization behavior.

## Current implementation

- The host's snapshots synchronize farm grids, calendar, time, weather,
  upgrades, and decoration; farm-grid changes also flow live between players.
- The guest currently joins using their local save and adopts the host's world
  snapshot into it. That is a stopgap: the target is a persistent farmhand slot
  tied to the co-op farm, while each player's solo save stays untouched.
- Inventory, money, skills, relationships, character identity, and story
  progress are not synchronized. Town, museum, and mine progression are not
  yet integrated as explicitly shared systems.
- There is no group sleep/readiness barrier yet. The host's day transition
  drives guests forward; a guest cannot hold the group at night by going to
  bed. The group sleep model above is planned behavior, not a current feature.
- A guest's original save is backed up before the first host snapshot. Preserve
  that first backup across reconnects; this is not a save-merge system.
- Dungeon floors, NPC behavior, and animal simulation are not shared.

## Architecture

- `mod/mt` is the in-game GML mod. It owns the multiplayer menus, remote-player
  display, world snapshots, and live farm-change detection.
- `companion` is a Rust program. It handles networking, LAN beacons, session
  hosting, and the file bridge between the game and network.
- The game and companion exchange small files in the game's mod-data folder;
  the game itself does not open network sockets.

## Connections

- Nearby discovery uses local IPv4 UDP broadcasts. It does not discover peers
  across arbitrary VPNs.
- Friends are local config entries with a user-chosen label and hostname/IP.
  Hostnames work when the network or VPN resolves them; labels are not verified
  Steam identities.
- Connections are not encrypted. Use a trusted VPN or network; the optional
  session password is not a substitute for transport encryption.

## Distribution

MOMI installs the extracted `mt/` directory with `manifest.toml` at its root.
Release bundles include that directory and a convenience ZIP. Keep the mod,
companion, and protocol versions aligned; change the protocol version only
when the network message format changes.

Public matchmaking, whole-save replication, automatic Steam identity lookup,
and general VPN peer discovery are out of scope.

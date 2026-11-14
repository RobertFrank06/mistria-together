# Mistria Together Design

This document holds the stable decisions: what Mistria Together is, why, and the
constraints every change must respect. It does not track progress. The ordered
work list, the status of each feature, and the technical notes needed to build
them are in [IMPLEMENT.md](IMPLEMENT.md). What players can use today is in
[README.md](README.md).

## 1. Purpose

Mistria Together brings Stardew Valley's co-op model to Fields of Mistria: two
to eight players on one persistent farm, with a host who owns the world,
farmhands who own their characters, and a day that only moves forward when the
group agrees.

Stardew is the reference for the rules, not for every detail. Where Mistria
works differently (its story scenes, its overnight summary, its magic, its
mines) the rule is restated here in Mistria's terms.

### Non-goals

- Public matchmaking, lobbies, or dedicated servers that run without a player.
- Merging two existing saves, or moving a farm from one host to another.
- Verified identity (Steam accounts). Player and friend names are labels.
- Transport encryption. Players are told to use a trusted network or VPN.
- Discovery across VPNs or the internet.
- Player-versus-player combat.
- Synchronizing NPC positions or monsters (see section 9).

## 2. Roles and ownership

- **Host.** The player whose save is the farm. Only the host's game writes the
  farm to disk. The farm is playable in co-op only while the host has it
  loaded and is hosting; the host can also play it alone.
- **Farmhand.** Any other player. A farmhand's character is a dedicated save
  file on the farmhand's own computer, one per co-op farm they have joined. It
  is created by the Join flow, never by hand, and it is never one of the
  player's solo saves.
- A farmhand save holds that player's character plus the last copy of the
  host's world they received. It cannot be played without its host: loading it
  outside a session with that farm returns the player to the title screen.
- A player's solo saves are never modified by the mod. Joining a farm while a
  solo save is loaded is refused.
- The session has at most eight players. Everyone must run the same version of
  the mod and companion.

## 3. Shared and personal

"Shared" means there is one truth, held by the host, that every player sees
and can change. "Personal" means each player has their own and nobody else's
game touches it.

| Shared (host-owned world) | Personal (each character) |
| --- | --- |
| Every location's grid: soil, crops, trees, rocks, forage, furniture, placed objects | Inventory, equipment, tools |
| Buildings and their interiors | Gold, in separate-wallet mode |
| Farm animals and their care state (fed, petted, produce) | Essence, renown, mana |
| Chest contents and the shipping bin | Skills, experience, perks, spells, recipes |
| Calendar, clock, weather and forecast | Relationships with townspeople, marriage, children |
| Farm expansion and the host's house upgrades | Quests and request-board progress |
| Museum collection | Mail, cosmetics, mount, pet |
| Deepest mine floor reached | Story scenes and heart events seen |
| World and area unlocks (bridges, repaired places, opened regions) | Health and stamina |
| Gold, in shared-wallet mode | |

Rules that follow from the table:

- Whoever performs an action gets its personal result: experience, the item in
  hand, the relationship point.
- A reward for shared progress (for example a museum set) is given to every
  player who was online when it was earned, each in their own inventory or
  mail.
- World and area unlocks follow the host's story progress. A farmhand starts
  without the prologue and sees the world as the host has opened it.
- Items change hands by being dropped or put in a chest. There is no trade
  window.

## 4. Time

- There is one session clock. The host's game owns it and every player's game
  follows it.
- **The session clock never waits for a player.** Opening a menu, an
  inventory, a shop, a dialogue or a story scene freezes only that player's own
  game. When it closes, their game catches up to the session clock.
- The host can pause the session for everyone from the multiplayer menu, and
  resume it. Nothing else pauses shared time. While paused, a notice is shown
  to all players.
- Before the first farmhand joins, the host's game behaves exactly as in
  single player.
- Actions that skip time in single player (recipes with a duration, scenes
  that jump the clock, oversleeping after passing out) do not move the session
  clock. The acting player gets the result without the skip.
- At 2:00 every player who is not already waiting for the night passes out.
  A player who is in a menu or scene at that moment passes out when it closes.
- Day length follows the host's setting.

## 5. Ending the day

- Going to bed means "I am ready for the night", not "start the night". The
  player lies down, sees who is ready and who is not, and can get up again.
- A player is also ready when they pass out, die, or finish any scene that
  ends the day in single player. Such a player cannot get up again; they wait
  at their overnight summary.
- The night starts when every online player is ready. The host announces it.
  Each player then goes through their own overnight summary.
- The host's game runs the real day transition and saves. It then sends the
  new morning to every farmhand, whose games adopt it before they can act.
  A farmhand's own overnight simulation never decides what the world looks
  like in the morning.
- A player who disconnects stops counting toward readiness. A player who joins
  during the night waits for the morning.
- No player can advance the day alone while others are online, by any path.
- The penalties and restorations of a night (stamina, health, passing-out
  costs) are personal and follow the single-player rules.

## 6. Money

- The host chooses the wallet mode: **separate** (default) or **shared**.
  A change takes effect the next morning.
- Separate: each player has their own gold. Income from the shipping bin is
  totalled by the host and split evenly between the players online when the
  night starts. Everything else a player earns or spends is their own.
- Shared: the farm has one balance, held by the host. Every player's earnings
  and spending apply to it, and nobody can spend below zero.
- Switching from separate to shared adds all online players' gold together.
  Switching from shared to separate splits the balance evenly between online
  players.
- Gold is never created or destroyed by synchronization: the same item is
  never paid for twice, and money is never moved by copying saves.

## 7. Players in the world

- Players see each other's character, appearance, animations, tools, held
  items and name.
- Players do not block each other's movement.
- A player in a story scene is hidden from the others until it ends.
- An item dropped on the ground is visible to everyone in that location. The
  first player to pick it up gets it; the host decides ties, so an item can
  never be picked up twice.
- A chest, and the shipping bin, can be open for one player at a time. Others
  are told who is using it.
- Machines, crops and farm animals are shared: whoever collects a product
  gets it.

## 8. Mines

- Players on the same mine floor share the same layout and see each other.
  Rocks and other breakable objects on a shared floor are shared.
- The deepest floor reached is shared.
- Monsters and their drops are local to each player. This is a stated
  limitation, not a goal.

## 9. Not synchronized

Each game simulates these on its own from the shared clock and calendar, and
they may differ between players: townspeople's exact positions, wild animals,
monsters, and visual effects. The design accepts this; nothing may depend on
them matching.

## 10. Menus

- The title screen has **Multiplayer** in the normal button list, directly
  after **New Game**. It opens a menu in Mistria's own style with **Join**,
  **Host** and **Settings**.
- Join offers nearby games, saved friends, adding a friend, and joining by
  hostname or address. Choosing a game shows the farm and continues the
  player's farmhand there, or creates one on first join.
- Host explains that hosting begins when the host loads a save.
- While playing, the multiplayer key (default F9) shows session status and
  offers disconnect; for the host it also offers pause and the wallet mode.
- Menus use the game's own button visuals and input navigation, and long lists
  stay navigable without leaving the screen.

## 11. Technical constraints

- **No sockets in the game.** The game's scripts cannot open network
  connections. All networking lives in the Rust companion; the mod and the
  companion exchange files in the game's mod-data folder.
- **No engine edits.** The mod uses MMAPI hooks and may wrap methods on live
  engine structs. It never ships changed engine scripts and never depends on a
  hook that the installed MOMI catalog lacks.
- **Host authority.** Any conflict is resolved by the host's state. The
  morning snapshot, built with the game's own save serializer and applied with
  its own loader, is the daily repair for anything that drifted.
- **Same seeds.** A farmhand save uses the host farm's game identifier, so the
  game's seeded daily generation (forage, dig sites, shop stock, request
  board) matches on every machine.
- **Save safety.** A host's world is never written into a solo save. An
  existing backup is never overwritten. A farmhand save is only written while
  its game holds the host's current world.
- **Ownership before sync.** A system is only synchronized after its place in
  the save (world or character) has been verified in the game's code.
- **Performance.** Per-frame mod work stays well under one millisecond on the
  farm; anything heavier is spread over frames or tied to a rare event.
- **Failure is contained.** A mod error must never crash the game or corrupt
  a save; a lost connection returns players to a consistent single-player
  state.
- **Versions.** `companion/Cargo.toml`, `mod/mt/manifest.toml` and
  `MT_VERSION` share one release version. `MT_PROTO` changes only when
  game-to-game messages change, and the companion's wire version only when the
  companion-to-hub protocol changes. Mismatched players are refused with a
  clear message.

## 12. Testing

- Behaviour is specified by automated scenarios that run two or more real game
  instances against each other and fail loudly.
- The test suite exists before the feature it tests. A feature is done when
  its scenario passes, not when it has been tried by hand.
- Tests run only in the isolated rig: its own copy of the game and its own
  save folders. They never touch the player's install or saves.
- Companion behaviour is covered by tests that use real sockets and real
  files without a game.

## 13. Architecture

- `mod/mt` is the in-game GML mod: menus, remote players, snapshots, change
  detection, and the rules in sections 4 to 8.
- `companion` is the Rust program: session hub, connections, LAN discovery,
  file transfer, and the file bridge.
- The companion runs in the background and does what the in-game menu asks.

## 14. Connections

- Nearby discovery uses local IPv4 UDP broadcasts. It does not cross VPNs.
- Friends are local entries: a label and a hostname or address.
- The host's session can be reached directly, or through a standalone relay
  that both sides connect out to.
- Connections are not encrypted. The optional session password keeps
  strangers out; it does not protect traffic.

## 15. Distribution

MOMI installs the extracted `mt/` directory with `manifest.toml` at its root.
Release bundles contain that directory, a convenience ZIP of it, the companion
and an installer for each operating system.

## 16. Decisions

| Date | Decision | Why |
| --- | --- | --- |
| 2026-11-10 | Networking in a separate companion, file bridge to the game | The game's scripting has no sockets |
| 2026-11-10 | World sync by snapshot plus change detection, not per-action hooks | Carries everything the save format carries; no hook covers every tile change |
| 2026-11-13 | Dedicated Mistria-styled multiplayer menu instead of chained popups | Clear Join/Host/Settings entry and room for friend lists |
| 2026-11-14 | Farmhand character stored on the farmhand's own computer | The game can only load a whole save; keeps solo saves untouched and needs no partial character loading |
| 2026-11-14 | Session clock never waits for menus or scenes; only the host's pause stops it | Matches Stardew; one player's inventory must not freeze everyone |
| 2026-11-14 | Both wallet modes, separate is the default | Matches Stardew; separate needs no shared ledger and is the safer default |
| 2026-11-14 | A player whose day ends early waits at the overnight summary | Every day-ending path in the game runs through the same function, which the mod cannot cancel; holding the summary is the one point all paths share |

## 17. References

- Stardew Valley Wiki, [Multiplayer](https://stardewvalleywiki.com/Multiplayer):
  host and farmhands, shared and personal progress, wallet modes, when time
  pauses, host commands.
- Stardew Valley Wiki, [Day Cycle](https://stardewvalleywiki.com/Day_Cycle):
  all players must be asleep or passed out, then confirm the overnight screen,
  before the day is saved.
- ConcernedApe, [Stardew Valley 1.6 update notes](https://www.stardewvalley.net/stardew-valley-1-6-update/).
- Mods of Mistria Installer, [MMAPI documentation](https://github.com/Garethp/Mods-of-Mistria-Installer/tree/main/docs/MMAPI).

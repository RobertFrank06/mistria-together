# Mistria Together co-op sharing and friends design

**Status:** implementation approved by the user on 2026-11-10.

## Intent

Make co-op feel like a shared farm while keeping each farmer's personal progress safe, and make returning to a remote friend's game a one-click action after setup. The user is leaning toward a Stardew-like model and asked for saved friends displayed by a recognizable name, potentially their Steam name.

## Goals

- Keep the host's farm and shared world state authoritative.
- Share suitable world and town progression between players while preserving player-specific progress.
- Offer shared or separate money if Mistria's save model supports that safely.
- Add an in-game Multiplayer settings view for existing options and co-op rules.
- Keep nearby LAN discovery and add a saved Friends list for remote play.
- Let a player label a saved connection with a friend's name; retain the hostname/address and port privately for reconnecting.
- Accept hostnames as well as IP addresses so any VPN with working name resolution can be used.

## Non-goals

- Copy an entire player's save over another player's save as a syncing strategy.
- Require Steam or Tailscale for co-op.
- Add a public matchmaking or rendezvous service in this scope.
- Read Steam persona names automatically. A saved friend's display name is user-entered; Steam integration can be considered separately.
- Promise automatic peer discovery across arbitrary VPN products. Their routing and discovery support differs.
- Perform a broad source-code rearrangement when there are no TODO/FIXME markers or obvious duplicated source files.

## Current behavior and constraints

- A guest adopts a snapshot of the host's farm grids, calendar, weather, farm and house upgrades, decoration, and maximum dungeon level. Live farm-grid changes are also synchronized.
- Before the guest first adopts the host's world in a session, the mod copies the guest's current save into its backup folder. The guest's own local save then holds the host's farm state when saved.
- Inventory, money, skills, relationships, and most quest/story state are not currently synchronized. Snapshotting selected grids is not equivalent to merging whole save files.
- The current join menu lists LAN beacons when available; otherwise it asks for an address. The companion resolves hostnames when connecting. Only the last address is currently remembered.
- LAN discovery sends IPv4 broadcast beacons. That works on networks that pass local broadcasts, but it does not provide a general VPN peer directory. A remote friend can use a VPN hostname/address without provider-specific code.
- Existing multiplayer options are stored in the local mod config. The Multiplayer popups do not yet provide a settings screen.
- The source tree is small (36 tracked files) and has no TODO/FIXME markers. The large `target/` tree and `dist/MistriaTogether-mod.zip` were local ignored build outputs; they have been cleaned from this checkout.
- README and packaged first-run instructions say the helper copies `MistriaTogether-mod.zip` into the MOMI mods folder. MOMI expects the extracted mod folder, with `manifest.toml` directly inside it, so the current release packaging/instructions are inconsistent with MOMI's install format.

## Approaches

1. **Keep current sharing and only add saved connections.** Smallest change, but leaves the requested shared progression and settings work unresolved.
2. **Shared world with personal farmers, plus a saved Friends list and settings view. Recommended.** Matches the user's Stardew-like direction without overwriting personal progress. Requires mapping which Mistria progression fields are global before synchronizing them.
3. **Replicate or replace whole saves.** Could appear to share everything quickly, but risks overwriting inventory, character, relationship, and story state and makes simultaneous saves conflict. Rejected.

The user has expressed a preference for approach 2 and for saved friend entries identified by a recognizable name. This document asks them to approve the concrete scope before implementation.

For package correctness and repository housekeeping, two viable approaches remain:

1. **Ship the extracted `mt/` folder next to the helper and copy it into MOMI's mods directory. Recommended.** The existing build already has the unpacked source, so the installer needs only recursive file copying. Keep the standalone mod ZIP as a release convenience, but do not present it to MOMI as an installable folder.
2. **Add ZIP extraction to the cross-platform helper.** Keeps the current package shape but adds archive parsing, path-safety, and replacement behavior to installer code.

Keeping the current ZIP-only copy is ruled out because MOMI does not install ZIP files. In either viable approach, update the README and first-run guide. Remove only generated local build output and truly redundant tracked files; preserve the compact authored source layout.

## Proposed behavior

### Joining and saved friends

- Multiplayer opens a view with **Nearby**, **Friends**, and **Settings**.
- **Nearby** retains current local discovery: show host name and player count, then a Join action. If no host appears, explain that nearby discovery only works on networks that pass the beacon and offer Friends or Add Friend.
- **Friends** shows saved cards by their user-entered display name. Selecting a card attempts the saved hostname/address and port. The connection address is not shown in the main list; an edit/details action can reveal it.
- **Add Friend** asks for a display name and a hostname/address once. Users may type a Tailscale MagicDNS hostname or another VPN/DNS hostname instead of an IP. Keep the last-address quick path for ad-hoc joining.
- Save friend entries in local mod configuration, not in the farm save, so they remain personal and do not sync to guests.
- A Steam display name can be typed as the label. Automatic Steam friend discovery is outside this version because it needs Steam-specific integration and an invitation/identity flow.
- Keep connection errors actionable (offline, name not resolved, or host not reachable) and allow editing/removing an entry.

### Settings

- Add an in-game settings view reachable from Multiplayer.
- Separate local presentation settings (HUD, name tags, movement smoothing) from host-owned session rules.
- Expose existing world synchronization as an understandable session option.
- Offer shared/separate money only after verifying where Mistria stores money and proving that host-authoritative updates do not overwrite personal data. If that cannot be done safely in this implementation, defer the toggle and explain the current behavior in the UI/README.
- Host's session rules are authoritative. Guests can view them but do not silently override the shared session.

### Shared progression

- Continue sharing the farm, time, weather, upgrades, decor, and world fields already supported.
- Before extending snapshots, inventory the game's save/load state and classify fields as shared-world or player-owned.
- Synchronize only fields that can be updated without replacing personal farmer state. Candidate shared fields include town/farm unlocks, shared quests, museum progress, and mines progress; each requires source-level confirmation before implementation.
- Keep inventory, skills, relationships, and character identity per player unless a future design explicitly adds a safe opt-in rule for one of them.
- Keep and verify the guest-save backup before any new field is adopted.

## Constraints and implementation calls

- Connection profiles should store a friendly label separately from the endpoint. This is a convenience label, not proof of Steam identity.
- No automatic VPN discovery service is included. Provider-neutral remote joining uses saved hostnames/address; LAN beacons remain opportunistic.
- Existing wire/session protocol should not need a breaking change just to store friend profiles or expose local UI settings. Shared progression may require a protocol version bump if new snapshot or live-sync message shapes are introduced.
- Cross-platform UI text and config migration must work with the existing MOMI/MMAPI configuration API.

## Acceptance criteria

- A player can save a remote host under a chosen name and reconnect from a visible friend card without retyping the endpoint.
- The flow accepts a DNS hostname as well as an IP and reports resolution/reachability errors clearly.
- Nearby LAN join still works and remains a separate path from VPN-hostname joining.
- Settings distinguish personal display choices from host-controlled shared-game rules.
- A guest's character-owned state is not replaced by new world synchronization; guest backups remain available.
- README accurately describes sharing, save ownership, LAN discovery, friend entries, and any deferred progression fields.

## Open implementation research

- Inspect Mistria's save/load ownership for town/story flags, museum progress, money, and player-owned state before choosing which fields can be shared.
- Confirm UI text input limits and whether a multi-entry list fits the current popup pattern cleanly.

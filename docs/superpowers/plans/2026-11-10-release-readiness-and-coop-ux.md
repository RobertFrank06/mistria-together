# Release Readiness and Co-op UX Implementation Plan

> **For agentic workers:** Use the approved spec and execute each task in this plan in order. Steps use checkbox syntax for tracking.

**Goal:** Make Mistria Together install correctly through MOMI, preserve guest saves, provide saved-friend and settings menus, and leave CI/repository quality checks clean.

**Architecture:** Keep networking in the Rust companion and co-op UI/config in the GML mod. Release packages will contain both the standalone ZIP and the extracted `mt/` mod directory; setup copies the extracted folder into MOMI's mods directory. Friend labels and endpoints stay in local mod configuration. World synchronization remains host-authoritative and is extended only for fields whose ownership is confirmed.

**Tech Stack:** Rust 2021, Tokio, GML/MMAPI, GitHub Actions, the existing isolated two-game test rig.

**Spec:** `docs/superpowers/specs/2026-11-10-coop-sharing-and-friends-design.md`

## Global Constraints

- MOMI must receive an extracted mod folder with `manifest.toml` inside it; a ZIP by itself is not installable.
- A guest's original save backup must never be replaced by a later co-op save.
- Friend labels are user-entered and are not verified Steam identities.
- Saved endpoints accept hostnames and addresses, without a Tailscale dependency.
- Per-player inventory, skills, relationships, and character identity remain personal.
- Do not add shared money, story, museum, or quest synchronization unless the save field and ownership can be proven safe.
- No public matchmaking service is introduced.

## Review Focus

- Existing `mt/` folder belongs to another mod: installer must refuse to replace it.
- Existing `mt/` is this mod: installer must update it and remove stale files without losing the previous copy if staging fails.
- The helper bundle lacks `mt/`: setup must report a useful recovery step, not place a ZIP in MOMI.
- A guest joins repeatedly: the first original-save backup remains byte-for-byte unchanged.
- Friend entries contain empty, duplicate, overlong, or malformed values: reject them clearly and preserve existing entries.
- DNS lookup fails or the remote host is offline: show a useful connection error without deleting the saved friend.

---

### Task 1: MOMI package correctness and safe updates

**Files:** `companion/src/install.rs`, `companion/src/main.rs`, `companion/Cargo.toml`, `.github/workflows/release.yml`, `tools/package-mod.sh`, `packaging/*`, `README.md`, install tests in `companion/src/install.rs`.

**Interfaces:** Keep `install() -> Result<Vec<String>>`. Add a small internal directory-install helper that accepts a bundled source folder and a selected mods folder; it validates the bundled manifest, stages the new `mt/`, and replaces only an existing matching Mistria Together mod.

- [ ] Add tests for copying the extracted mod tree, replacing an existing matching version, refusing a different mod at `mods/mt`, and leaving the prior version recoverable when staging fails.
- [ ] Run `cargo test --locked install::tests` and confirm the new behavior fails before implementation.
- [ ] Update release packaging to include extracted `mt/` next to the helper while retaining the ZIP for manual use.
- [ ] Implement staged directory copying and safe replacement in `install.rs`; never copy a ZIP into MOMI's mods folder.
- [ ] Update `install`/`uninstall` output, README, and first-run guide to describe the extracted folder.
- [ ] Run the focused install tests and inspect the built archive contents for both `mt/manifest.toml` and the optional ZIP.

### Task 2: Preserve guest save backups

**Files:** `mod/mt/gml/MtSync.gml`, `mod/mt/gml/MtDev.gml`, `tools/e2e.sh` or a focused new rig helper.

**Interfaces:** Keep `mt_sync_backup_save()` as the single entry point. Mark backup state only after an existing or newly created backup has been verified. Preserve an existing backup rather than deleting it.

- [ ] Add a rig scenario that joins the host twice and records the original guest-save backup hash after the first join.
- [ ] Run it against the current code and confirm the second join changes the backup hash (the expected regression).
- [ ] Make backup creation idempotent: an existing backup is kept; failed/missing source copies remain eligible for retry.
- [ ] Run the rig scenario twice and confirm the backup hash is unchanged and the logs report the preserved backup.

### Task 3: Saved Friends

**Files:** `mod/mt/gml/MtBoot.gml`, `mod/mt/gml/MtMenu.gml`, `mod/mt/gml/MtDev.gml`, `tools/rig.sh`, and the multiplayer menu test path.

**Interfaces:** Add config helpers for validated friend entries shaped as `{ name: string, address: string }`. Keep endpoint parsing/connection in the existing companion; send only the selected entry's address to `mt_menu_set("join", address)`.

- [ ] Add dev-rig cases for add, persistence after game restart, duplicate/empty rejection, selection, and removal; confirm they fail before implementation.
- [ ] Implement a Friends list with named cards, Add, Join, and Remove; save entries in local mod config, not the farm save.
- [ ] Preserve nearby discovery and the existing one-off address entry; allow hostnames in saved entries.
- [ ] Run the isolated menu tests and inspect displayed text to ensure addresses are hidden from the normal friend list.

### Task 4: Multiplayer Settings and shared-progress boundary

**Files:** `mod/mt/gml/MtMenu.gml`, `mod/mt/gml/MtBoot.gml`, `mod/mt/gml/MtSync.gml`, `README.md`, and rig tests where state can be observed.

- [ ] Add UI controls for existing local options: HUD, name tags, movement smoothing, menu key, and session password.
- [ ] Clearly show the current shared-farm behavior and keep host-synchronized world state separate from personal display choices.
- [ ] Inventory available runtime/save fields for shared money, museum/town progression, and quest/story progression using the installed game metadata and runtime APIs.
- [ ] Add a shared field only if both ownership and save/load behavior can be demonstrated; otherwise leave it personal, omit the toggle, and document it as not shared yet.
- [ ] Run isolated rig checks for settings persistence and confirm guest inventory/identity are unchanged by snapshots.

### Task 5: Repository and CI cleanup

**Files:** Rust source files flagged by `cargo fmt`/Clippy, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.gitignore` if needed.

- [ ] Fix the baseline Clippy findings in `bridge.rs` and `client.rs`; add a check to CI.
- [ ] Apply rustfmt consistently and add `cargo fmt --all -- --check` to CI.
- [ ] Update GitHub Actions to Node 24 compatible releases: checkout v7, upload-artifact v6, download-artifact v7; pin the release job runner to `ubuntu-24.04`.
- [ ] Re-run formatting, Clippy, `cargo test --locked`, release build, archive inspection, and isolated game-rig checks.
- [ ] Confirm only source/docs changes remain tracked; clean generated `target/` and `dist/` outputs after verification.

### Task 6: Version and release preparation

**Files:** `Cargo.toml`, `mod/mt/manifest.toml`, `mod/mt/gml/MtBoot.gml`, `.github/workflows/release.yml`.

- [ ] Bump companion and mod versions consistently for the user-facing changes and update the protocol version only if wire messages change.
- [ ] Build all platform packages through CI and verify Linux, Windows, and macOS assets include the executable, extracted mod, standalone ZIP, license, and accurate first-run guide.
- [ ] Prepare release notes that clearly list shared farm behavior, personal progress boundaries, saved-friend setup, and any deferred shared progression.

# Mistria Together Implementation Plan

This is the working checklist for building what [DESIGN.md](DESIGN.md)
describes. DESIGN.md holds the decisions; this file holds the order of work,
the status, and the technical notes needed to do it. Tick boxes as tasks land.
If a task forces a change to a rule, change DESIGN.md first, in its own commit.

**Order is binding: Phase 0 (the test suite) is finished before any feature
phase starts, and inside every feature task the scenario is written and seen
to fail before the feature code is written.**

## Status

| Phase | What | State |
| --- | --- | --- |
| shipped | Remote players, snapshot + live farm sync, host time/weather, multiplayer menu, background companion, LAN discovery (v1.1.0) | done |
| 0 | Test suite | not started |
| 1 | Session clock and host pause | not started |
| 2 | Group day end | not started |
| 3 | Farmhand saves | not started |
| 4 | Money and shipping | not started |
| 5 | Shared progress and animals | not started |
| 6 | Dropped items and chest locking | not started |
| 7 | Scenes and festivals | not started |
| 8 | Mines | not started |

Known gaps in what is shipped, all closed by the phases below: the host's
menus pause everyone (Phase 1); a guest can be dragged through the night or
sleep alone (Phase 2); a guest joins with whatever save is loaded and the
save guard is an empty stub in `MtSync.gml` (Phase 3); every game pays out the
full shipping bin (Phase 4).

## Ground rules for whoever implements this

1. Read `AGENTS.md` and `DESIGN.md` first. Never install into the real game or
   touch real saves; use `tools/rig.sh` only.
2. One task = one commit (or a few), in the listed order. Do not start a task
   whose "needs" are not ticked.
3. Test first. For each task: add the scenario named in the task, run it, see
   it fail for the expected reason, then implement until it passes, then run
   the whole suite.
4. GML dialect rules that have already cost time (all verified in this game):
   - `mod` is a reserved word. `noone` does not exist: use `undefined`.
   - Reading a missing struct field with `.` throws: use `s[$ "field"]`.
   - Every function you call must exist, or the whole mod fails to compile.
     Never call another mod's functions.
   - Top-level code runs at boot with no file IO. Do work in the tick
     (`mt_tick`) or in a hook.
   - All function names start with `mt_` (the mod folder is `mt`; MOMI lints
     this). State lives in `global.__mt` (`__mt_rt()`).
   - Text drawn by hand needs the font palette (`mt_ui_text_begin`).
   - `save_json_file`/`json_stringify` crash on methods and instance refs.
     Send plain structs only.
   - Enum names must exist (`GroundKind.Soil`, not `Tilled`); a wrong one
     crashes the game at boot. Grep the game scripts before using any enum.
5. A grid object's identity is its parent's `top_left_x/y`; that cell is often
   not occupied by the object (trees). Use `mt_sync_find_by_root`.
6. Never set `GRID` yourself. Change rooms with a `TaxiItinerary`.
7. Wrap every hook handler body that touches game state in `try/catch` and log
   with `mmapi_warn_rate_limited`. A throwing handler must never break play.
8. After any change to messages between games bump `MT_PROTO` (`MtBoot.gml`).
   After any change to companion/hub frames bump `WIRE_VERSION`
   (`companion/src/proto.rs`). Keep the three version strings equal.
9. Useful checks are listed in `AGENTS.md`. Run them before each commit.

### Reading the game's scripts

The pristine scripts are inside the game's backup archive. Read them in place:

```sh
Z="$HOME/.local/share/Steam/steamapps/common/Fields of Mistria/assets.bak.zip"
unzip -l "$Z" 'assets/gml/*' | awk '{print $4}'                    # list files
unzip -p "$Z" assets/gml/scripts/GameplaySystems/Cycle/EndDay.gml  # print one
```

Scene scripts are in `assets/mist_scripts/`, data in `assets/fiddle/`. Hook
contracts are in the MOMI repository under `docs/MMAPI/hooks/<name>.md`. The
installed hook list is `assets/gml/scripts/mmapi/mmapi_hook_catalog.gml` in the
modded `assets.zip`. Line numbers below are for game v1.0.8; re-grep if the
game has updated.

---

## Phase 0: Test suite

Goal: an automated, assertion-based suite that drives real game instances in
the rig, plus fast checks that run in CI where the game is not available.

### 0.1 Scenario runner

- [ ] **Files:** new `tools/gametest.py`, new `tools/gametest/__init__.py`
  (helpers), new `tools/gametest/scenarios/`. Python standard library only.
- [ ] **CLI:** `tools/gametest.py list`, `tools/gametest.py run [name ...]
  [--keep] [--players N] [--timeout S]`. Exit code 0 only if every selected
  scenario passed. Print one line per assertion and a final summary. On
  failure, copy each instance's stdout log, mod log and last `dev_state.json`
  to `$MT_RIG/failures/<scenario>/` and print that path.
- [ ] **Lifecycle per scenario:** `rig.sh install` once per run (not per
  scenario) -> wipe each instance's `mod_data` and `saves` -> start one
  background companion per instance (`mistria-together daemon --data-dir
  <rig>/<p>/FieldsOfMistria`) -> start instances with
  `MISTRIA_TOGETHER_DEV=new` -> wait until every `dev_state.json` reports
  `in_world: true` -> run the scenario function -> stop everything.
  Reuse `tools/rig.sh` for `install`, `run`, `stop`; do not duplicate it.
- [ ] **Process hygiene:** start children in their own process group and kill
  the group in a `finally`. Never use `pkill -f` with a pattern that can match
  the runner's own command line (this killed the shell twice).
- [ ] **Helper API** (`tools/gametest/__init__.py`), used by all scenarios:
  - `Game(name)` with `.cmd(command: dict) -> dict` (send a dev command, wait
    for and return its result, raise on error or timeout),
    `.state() -> dict`, `.wait(predicate, what, timeout=20)`, `.log()`.
  - `session.host`, `session.guests`, `session.all`.
  - `session.connect()` : host picks Host via the `menu` dev command, guests
    join by LAN, wait until all report `online` and guests report the host's
    world adopted.
  - `expect(condition, message)`, `expect_equal(a, b, message)`,
    `expect_same_world(games, where="near")` (compares world digests and
    prints a small diff).
  - `screenshot(game, path)` via `gamescopectl` (best effort, never fails a
    scenario).
- [ ] **Scenario shape:** each file defines `NAME`, `PLAYERS = 2`,
  optional `SETUP = "farm"` (teleport everyone to the farm at 800,800 first)
  and `def run(session): ...`.
- [ ] **Done when:** a trivial scenario `smoke_boot` (two instances reach
  `in_world`) passes, and a deliberately false `expect` makes the runner exit
  non-zero with the artifacts saved.

### 0.2 Dev hooks the suite needs

- [ ] **File:** `mod/mt/gml/MtDev.gml` (plus small `mt_*_dev_*` helpers in the
  file that owns each system). Everything stays inert unless
  `MISTRIA_TOGETHER_DEV` is set.
- [ ] **Command results.** Today commands only append to a log. Change
  `mt_dev_run` so every command file `dev_cmd_<n>.json` produces
  `dev_res_<n>.json` = `{ n, ok, error, value }`, written with
  `mt_ipc_write`. `value` is whatever the command returns (plain struct).
  The runner's `.cmd()` waits for that file. Keep `dev_state.json`.
- [ ] **World digest.** Move the "near" list out of `mt_sync_dev_state` into a
  command `digest { scope: "near" | "grid", radius }` returning sorted strings
  for soil, objects (id, root, hit points, stage) and chest contents. Stop
  computing it every 15 frames.
- [ ] **Real-tool actions.** The current `till` dev command writes soil
  directly and produced a false difference (grass regrows on it overnight and
  the game's loader rejects it). Replace test actions with the functions the
  game's own tools call, and record which function was used next to each
  command. Where no clean function exists, keep the direct write but make the
  digest ignore what the game itself would not save.
- [ ] **New commands** (add each when the phase that needs it starts; listed
  here so names stay consistent):
  `clock { set }`, `host_pause { on }`, `menu_open { kind }`, `menu_close`,
  `bed { action: "sleep" | "get_up" }`, `faint`, `die`, `night_state`,
  `summary_next`, `gold { set | add }`, `gold_get`, `give { item, count }`,
  `inventory`, `bin_put { item, count }`, `bin_value`, `chest_open { x, y }`,
  `chest_close`, `drop { item }`, `pickup_nearest`, `items_near`,
  `donate { item }`, `museum`, `animal { action }`, `facts { keys }`,
  `save`, `save_info`, `quit_to_title`, `join { addr }`, `scene { name }`,
  `mine { floor }`.
- [ ] **Done when:** `tools/gametest.py run smoke_commands` passes: it calls
  `digest`, `clock`, `gold_get` on both instances and checks the result
  shapes.

### 0.3 Port the existing manual checks

Each becomes one scenario file. These must pass against v1.1.0 behaviour
before any feature work (they are the regression net).

- [ ] `join_snapshot`: after `session.connect()`, guests' near digest equals
  the host's on the farm.
- [ ] `live_changes`: host erases an object, damages one, tills and waters;
  guest erases a different object and tills; both digests equal within 5 s.
- [ ] `away_and_back`: guest leaves the farm, host changes it, guest returns;
  digests equal.
- [ ] `host_new_day`: host runs the day transition; guests' calendar equals
  the host's and digests are equal.
- [ ] `reconnect`: kill and restart the guest's companion; guest comes back
  online and digests are equal.
- [ ] `menu_lan_join`: host and guest driven only through the `menu` command;
  the guest finds the host in `link.json`'s `lan` list.
- [ ] `movement_smooth`: guest moves 120 frames; the host's per-frame trace of
  the ghost has no step larger than twice the mean step and ends within 2 px
  of the guest's real position.
- [ ] Delete `tools/e2e.sh` and `tools/e2e_compare.py`; update `README.md`
  "Building and testing" and `AGENTS.md` "Useful checks" to name
  `tools/gametest.py`.

### 0.4 Checks that run in CI

CI has no game, so it cannot run scenarios. It can still catch most GML
mistakes.

- [ ] **GML compile gate.** New `tools/check-gml.sh`: builds `momi-gml-check`
  from the MOMI repository (`tools/checker`, pinned to the MOMI tag the
  manifest's `minInstallerVersion` names) into `target/tools/`, then runs
  `momi-gml-check unit mod/mt/gml/*.gml`. Add a CI job that runs it on Linux
  and caches the build.
- [ ] **Static rules script** `tools/lint-gml.py` (stdlib): fails on `noone`,
  on a top-level `function` not starting with `mt_` or `__mt_`, on `\bmod\b`
  used as an identifier, on any call to an `mt_*` function that is not
  defined in `mod/mt/gml`, and on any `t: "<x>"` message type that has no
  `case "<x>"` handler (and the reverse). Add to CI.
- [ ] **Fix what the lint finds first.** Known today: `MtNet.gml:97` handles
  message type `em` by calling `mt_players_on_emote`, which is not defined
  anywhere. Remove that case (no game sends `em`).
- [ ] **Pure-logic unit tests.** New `mod/tests/*.gml` run with
  `momi-gml-probe` (built by the same script). Each test file includes the
  pure functions under test by concatenation (the probe runs one file) and
  ends by printing `PASS` lines; `tools/check-gml.sh --unit` fails on any
  missing `PASS` or any `FAIL`. First tests: ghost interpolation timeline
  (`mt_ghost_step` maths extracted into a pure `mt_interp_*` function), and
  the Phase 2 ready-set logic once written. Engine globals are stubbed in a
  shared `mod/tests/stubs.gml`.
- [ ] **Companion tests** stay as they are (`cargo test`); each phase that
  changes the companion adds its test to `companion/tests/session.rs` first.
- [ ] **Done when:** CI is green with the new jobs, and breaking a GML file on
  purpose (a missing brace; a `noone`) turns it red.

### 0.5 Spikes: settle the risky unknowns

These are throwaway experiments written as scenarios under
`tools/gametest/scenarios/spike_*.py`, with their dev commands. Each ends with
a short "Result" paragraph added to the "Verified game facts" section of this
file. Later phases rely on these results; if a spike fails, stop and revise
the phase (and DESIGN.md if a rule cannot be met) before building on it.

- [ ] `spike_bed_override`: register an `object.interact` override that
  claims nodes with `node.prototype.bed_kind != undefined`. Confirm the
  vanilla sleep popup no longer appears, that returning `undefined` restores
  it, and that calling `MIST.request_scene("sleep")` later from the mod (with
  `ARI.last_bed_used` set as the game does at `Interact.gml:708`) runs the
  normal night.
- [ ] `spike_summary_hold`: trigger `faint`, catch `ui.menu_opened` with
  `kind == Menu.Eod`, and keep the player on the summary: find the "next day"
  button node on the menu instance and lock it (`.lock()`), then unlock it
  after 10 s and confirm the day completes normally. Record the field name of
  that button and whether gamepad/keyboard confirm is also blocked.
- [ ] `spike_clock_jump_wrap`: in the tick, replace `CLOCK.jump` with a mod
  function (store the original in `CLOCK.__mt_jump`; re-apply each frame when
  the marker is missing, because `new_day` builds a new `Clock`). Confirm a
  timed recipe no longer advances the clock when the wrapper declines, and
  that calling the stored original still moves townspeople correctly.
- [ ] `spike_clock_follow`: with a menu open (`PauseStatus.MENU`), advance a
  separate number each frame; on close call the original `CLOCK.jump` to it.
  Confirm townspeople and the pet end up where the time says, and measure the
  hitch for a 2-hour jump.
- [ ] `spike_load_with_ident`: from the title, build
  `LoadState.New({...})`, overwrite its `game_ident` field with a chosen
  number, call `Setup.enter_game`, save, and confirm the file is
  `saves/game-<ident>-autosave.sav`. Then from a fresh boot load that file
  through `Setup.save_manager.manifest` and `LoadState.Load`.
- [ ] `spike_modsave`: confirm `mmapi_modsave_register` data round-trips for
  that save and is absent for another save.
- [ ] `spike_bin_drain`: put items in the shipping bin, clear the bin
  inventories in the `ui.menu_opened(Menu.Eod)` handler, and confirm the
  summary pays 0 for them (that the handler runs before
  `sell_shipping_bin_items`, `EodMenu.gml:96`).

---

## Phase 1: Session clock and host pause

DESIGN.md section 4. Needs: Phase 0.

**Concept.** Add a session time `st` (game seconds of day) owned by the host.
The host advances `st` every tick by the game's own per-frame amount unless
the session is paused or a night is running; guests receive it. Every machine
keeps its local `CLOCK.time` close to `st`, but only when its own game is not
paused. Local pauses therefore freeze the local world and catch up afterwards.

- [ ] **1.1 Scenarios first** (`clock_*`):
  - `clock_host_menu`: host opens a pausing menu for 5 s; the guest's clock
    keeps advancing during it; after the host closes it both clocks are
    within 2 game minutes.
  - `clock_guest_menu`: same with roles swapped.
  - `clock_host_pause`: host pauses; both clocks stop within 1 s; resume; both
    run.
  - `clock_no_skip`: a time-skipping action on the guest (use the wrapped
    `CLOCK.jump` directly through a dev command) leaves the session time
    unchanged on both.
  - `clock_solo_unchanged`: with no guest online the host's menu pauses its
    clock exactly as in single player.
- [ ] **1.2 Host session time** (`MtWorld.gml`): fields `st`, `st_paused`,
  `st_night`. Each tick on the host, if a guest is online and not paused and
  not in a night: `st += GAME_SECONDS_PER_FRAME` (macro in
  `scripts/GameplaySystems/TimeSeasons/Clock.gml:1`), capped at `hours(26)`.
  When no guest is online, `st = CLOCK.time` (single-player behaviour). When
  the first guest joins, `st = CLOCK.time`.
- [ ] **1.3 Local clock follows** (all machines): replace the current
  `mt_world_filter_time_advance` logic. While online with others, the
  `clock.time_advance` filter returns `0` (the local clock no longer
  self-advances); in the tick, when `!game_paused()`: if `st - CLOCK.time` is
  between 0 and 120, set `CLOCK.time = int64(st)`; if larger, call the
  original jump (from 1.4) with `st`; never move the clock backwards by more
  than the tolerance; if the local clock is ahead by more than 120, leave it
  until `st` catches up. Use the spike result for the hitch threshold.
- [ ] **1.4 Wrap `CLOCK.jump`** (pattern from `spike_clock_jump_wrap`): while
  online with others, calls not made by the mod are ignored (log at debug).
  Callers that are affected (all verified): timed recipes
  (`scripts/GameplaySystems/Recipe.gml`, `CLOCK.jump(CLOCK.time + count)`),
  scene `end_time_jump` (`Mist.gml:944`), oversleep
  (`AriUtils.gml`, `OVERSLEEP_TIME_TARGET`).
- [ ] **1.5 Message.** Extend `tm` (host -> all, every 30 frames and on
  change): `{ t:"tm", cal, st, pz, night, w, fc }`. `pz` is now only the
  host's explicit pause. Guests extrapolate `st` between messages by adding
  the per-frame amount while `pz == 0`. Bump `MT_PROTO`.
- [ ] **1.6 Host pause UI** (`MtMenu.gml`): in the F9 status view, host only:
  "Pause game" / "Resume game". HUD shows "Paused by <host>" for everyone
  (`MtUi.gml`). While paused, each game also sets its local
  `CLOCK.time_stopped`-independent freeze by returning 0 from the filter (the
  world keeps animating; only time stops, as in Stardew).
- [ ] **1.7 2:00.** No extra code: every machine's `should_faint`
  (`objects/characters/obj_ari.gml:1383`) fires when its clock reaches
  `hours(26)`; with the clock following `st` that happens together. Add
  scenario `clock_two_am` (set `st` to 25:59 on the host; both players faint;
  hand-off to Phase 2 is asserted there).
- [ ] **1.8 Day length.** The host's day-length setting decides the pace:
  add `mpd` (the host's `MINUTES_PER_DAY`, `scripts/GameplaySystems/TimeSeasons/Time.gml`)
  to `tm`; guests set their `MINUTES_PER_DAY` to it while online and restore
  their own value on disconnect. Scenario `clock_day_length`: host on a
  slower setting; after 30 s both clocks have advanced by the host's amount.
- [ ] **Done when:** the six scenarios pass and Phase 0.3 still passes.

## Phase 2: Group day end

DESIGN.md section 5. Needs: Phase 1, spikes `bed_override`, `summary_hold`.

**Concept.** New file `mod/mt/gml/MtNight.gml`. The host keeps a ready set.
There are two ways to become ready:

- *Bed (cancellable).* The mod takes over the bed interaction. Saying yes
  puts the player in a "waiting in bed" state owned by the mod; nothing of the
  game's night has run yet.
- *Held (not cancellable).* The game's own day-ending path has already
  started (`end_day`, `scripts/GameplaySystems/Cycle/EndDay.gml:2`, reached
  from `pass_out`, the `dying` scene and any scene with `ends_day = true`,
  `Mist.gml:926`). The mod cannot cancel it, so it holds the player at the
  overnight summary (`Menu.Eod`) by locking its continue button.

When the host sees every online player ready it broadcasts the night. Bed
players then run the game's real sleep scene; held players get their button
back.

- [ ] **2.1 Scenarios first** (`night_*`):
  - `night_both_sleep`: both use the bed; the calendar advances once on both;
    digests equal in the morning; each player's stamina is restored.
  - `night_one_waits`: only the guest sleeps; 10 s later the day has not
    advanced and the guest reports `waiting`; guest gets up; guest can move;
    host's ready list is empty.
  - `night_guest_cannot_advance`: guest sleeps; assert the guest's game never
    reaches `new_day` (calendar unchanged) while the host is awake.
  - `night_faint_holds`: guest `faint`s at noon; guest sits at the summary
    with the button locked; host sleeps; both advance.
  - `night_host_faints`: host faints at noon; the session clock keeps running
    for the guest (asserts Phase 1's `st` is used, not the host's `CLOCK`);
    guest sleeps; both advance.
  - `night_two_am`: at 2:00 both faint and the night runs without input
    beyond each summary's confirm.
  - `night_disconnect`: guest is ready, host is not, guest disconnects; host
    can sleep and advance alone. And the reverse: host ready, guest drops,
    night starts.
  - `night_join_during`: a third instance joins while the night runs; it
    receives the morning and is not counted.
- [ ] **2.2 Unit test first:** pure function
  `mt_night_all_ready(online_ids, ready_ids)` and the state transitions, in
  `mod/tests/night.gml`.
- [ ] **2.3 Bed takeover:** register `mmapi_override("object.interact",
  mt_night_on_interact)`; add `"object.interact"` to `requires_hooks`. Claim
  only when online with at least one other player and
  `ctx.prototype.bed_kind != undefined` and the game's own conditions hold
  (`is_home_location`, `requirements_pass(Requirement.Sleep)`,
  `Interact.gml:72` and `:695`); otherwise return `undefined`. On claim show
  a popup in the game's style ("Go to sleep?" Cancel / Sleep). On Sleep:
  record the bed exactly as the game does (`ARI.last_bed_used = {
  location_id, ni }`, `Interact.gml:708`), enter the waiting state, send
  `nr`.
- [ ] **2.4 Waiting state:** the player lies in bed (play the sleep loop
  animation on `obj_ari.par`; block movement by keeping a mod popup open with
  one button, "Get up", and the list of players with ready/not-ready). "Get
  up" clears the state and sends `nr` with `r:0`. The waiting popup refreshes
  when the ready set changes.
- [ ] **2.5 Held state:** on `player.pass_out` and `player.died` (add both to
  `requires_hooks`) set a flag; on `ui.menu_opened` with `kind == Menu.Eod`
  while online with others: lock the continue button (field from the spike),
  show "Waiting for the other players", send `nr` with `held:1`. Any
  `Menu.Eod` opening without a prior bed start is treated the same way, which
  covers day-ending scenes.
- [ ] **2.6 Host ready set:** host stores `ready[id] = { held }`, removes an
  id on `leave`, and broadcasts `ns { ready:[ids], n }` on every change. When
  all online ids (including the host) are ready, the host sets `st_night`,
  broadcasts `ng { day }`, and starts its own night.
- [ ] **2.7 Running the night on each machine:** on `ng`: bed players close
  the waiting popup and call `MIST.request_scene("sleep")` (the game then
  runs `end_day` -> summary -> `new_day` -> save, `EodMenu.gml:938-972`); held
  players get the button unlocked. Players who are neither (should not happen)
  are put through `pass_out(true)`.
- [ ] **2.8 Morning:** the host's `game.new_day` handler already queues a
  snapshot for everyone (`mt_sync_on_new_day`). Change the guest side: after
  its own `game.new_day`, the guest sets "awaiting morning", keeps the player
  from acting (a small "Waiting for the host's morning" popup) and requests
  the snapshot; it is released when the snapshot with the new `cal` is
  applied. The host clears `st_night`, resets `st` to `hours(6)` and clears
  the ready set when its `game.new_day` fires.
- [ ] **2.9 Guards:** a guest whose `game.new_day` fires without an `ng` for
  that day logs a warning and immediately requests a snapshot (existing
  fallback); the scenario `night_guest_cannot_advance` must show this path is
  not reachable through the bed.
- [ ] **Messages** (reliable): `nr { t, r:0|1, held:0|1 }` guest/host ->
  host; `ns { t, ready:[id], total }` host -> all; `ng { t, day }` host ->
  all. Bump `MT_PROTO`.
- [ ] **Done when:** all `night_*` scenarios and the whole earlier suite pass.

## Phase 3: Farmhand saves

DESIGN.md section 2 and the "same seeds" and "save safety" constraints.
Needs: Phase 2, spikes `load_with_ident`, `modsave`.

**Concept.** A farm is identified by the host's game identifier
(`Game.unique_identifier`, the `<ident>` in `saves/game-<ident>-autosave.sav`,
`scripts/Serialization/Serde/SerdeUtils.gml:8`). A guest's farmhand for that
farm is a local save with the *same* identifier, tagged by the mod as a
farmhand save. The Join flow, at the title screen, learns the farm's
identifier before any save is loaded, then loads or creates that save.

- [ ] **3.1 Companion test first** (`companion/tests/session.rs`):
  `session_info_before_ready`: a companion in menu mode whose game is at the
  title asks the hub for session info and receives the host's farm id, farm
  name, host name and player count without joining the roster.
- [ ] **3.2 Wire:** new frames `Query` (client -> hub, no body) and `Info {
  farm_id, farm_name, host_name, players, game_proto, mod_version, locked }`
  (hub -> client). The hub fills `Info` from the host's `Hello`, which gains
  `farm_id` and `farm_name`. Bump `WIRE_VERSION`. The game writes `farm_id`
  (string of `Game.unique_identifier`) and `farm` into `game.json`
  (`MtIpc.gml`, `mt_ipc_write_game`); `bridge.rs` `GameFile`/`GameInfo` carry
  them.
- [ ] **3.3 Control:** `control.json` gains `mode: "query"` with `addr`; the
  companion answers by publishing `info` (or `info_error`) in `link.json`.
  LAN beacons also carry `farm_id` and `farm_name` so nearby games show their
  farm without a query (`lan.rs`).
- [ ] **3.4 Scenarios first** (`farmhand_*`; these start instances with
  `MISTRIA_TOGETHER_DEV=title` and drive the menu through dev commands, so
  add a title-screen command channel: a chain-driven poll in `MtDev.gml`,
  because the tick does not run on the title):
  - `farmhand_first_join`: guest joins from the title; a new save
    `game-<host ident>-autosave.sav` appears in the guest's saves after the
    first night; the guest is in the host's world.
  - `farmhand_rejoin`: restart the guest game, join again; the same character
    (name, a given item, gold) is back.
  - `farmhand_solo_refused`: guest loads an ordinary save and tries to join
    from F9; refused with a message; the solo save file's bytes are unchanged
    (hash before/after).
  - `farmhand_offline_refused`: guest loads the farmhand save from the normal
    load menu with no session; it is returned to the title with a notice.
  - `farmhand_no_early_save`: a guest save attempt before the host's world is
    adopted is vetoed.
- [ ] **3.5 Tag:** `mmapi_modsave_register(MT_MOD, mt_save_collect,
  mt_save_apply)` storing `{ v:1, role:"host"|"farmhand"|"solo", farm_id,
  host_name, farm_name }`. A host's save is tagged `host` the first time it
  hosts (informational only).
- [ ] **3.6 Join flow** (`MtMenu.gml`): choosing a game (nearby, friend,
  direct) sends `query`; the menu then shows the farm and either "Continue as
  <name>" (a local save with that ident exists in
  `Setup.save_manager.manifest` and its tag says farmhand of this farm) or
  "Create your farmhand". If a local save has that ident but is not tagged
  farmhand (it is the player's own farm with a colliding id) refuse and say
  so.
- [ ] **3.7 Create:** run the game's character creation
  (`start_character_creation(preset, callback, true)`,
  `scripts/GameplaySystems/Cycle/NewGame.gml:326`), then build
  `LoadState.New({ name, farm_name: <host farm name>, pronouns, presets,
  preset_index_selected, birthday })`, set `global.__story_enabled = false`
  (no prologue; world progress follows the host), overwrite
  `load_state.game_ident` with the farm id, set the pending tag, write
  `control.json` `join`, and call `Setup.enter_game(load_state)`.
- [ ] **3.8 Continue:** `LoadState.Load(bundle)` for that save,
  `patch_save(loader)`, write `control.json` `join`, `Setup.enter_game`.
- [ ] **3.9 Refusals:** (a) in-world F9 Join is only offered when the loaded
  save is tagged farmhand of a farm; otherwise the menu explains to join from
  the title. (b) On the first tick after a load, if the save is tagged
  farmhand and the mod is not in the middle of a join for that farm id, call
  `Game.exit_to_menu()` and show a notice on the title. (c) On `welcome`, if
  the host's farm id differs from the save's tag, disconnect with a message.
- [ ] **3.10 Save guard:** replace the stub `mt_sync_save_guard`: for a
  farmhand, return `false` unless the host's world is adopted and no snapshot
  is pending; for anyone, allow otherwise. Remove the solo-save backup path
  from the join flow only after `farmhand_solo_refused` passes; keep
  `mt_sync_backup_save` for hosts upgrading from older versions and never
  overwrite an existing backup.
- [ ] **Done when:** all `farmhand_*` scenarios and the earlier suite pass;
  README install/play text is updated for the new Join flow.

## Phase 4: Money and shipping

DESIGN.md section 6. Needs: Phase 2 (night), Phase 3 (stable characters),
spike `bin_drain`.

Facts: gold is `ARI.gold`, changed through `Ari.modify_gold`
(`scripts/GameplaySystems/Player/Ari.gml:362`), which fires the
`player.gold_delta` filter; `set_gold` (`:349`) does not. The shipping bin is
a furniture node; bins are listed by `shipping_bins()` (`Ari.gml:1156`) and
paid only in `sell_shipping_bin_items()` (`EodMenu.gml:975`), called from the
summary's `init` (`:96`), as one `modify_gold` call.

### 4A Separate wallets (first)

- [ ] **Scenarios first** (`money_*`):
  - `money_bin_split`: host and guest each put items in the bin; after the
    night each player's gold rose by exactly half the bin's value (odd
    remainder to the host); the bin is empty on both.
  - `money_no_double_pay`: total gold across players after the night equals
    total before plus the bin's value.
  - `money_personal_spend`: the guest spends gold; the host's gold is
    unchanged.
  - `money_faint_no_early_pay`: a guest who faints at noon is not paid at
    that moment; they are paid their share when the night runs.
- [ ] **Bin value:** when the host broadcasts `ng`, it first computes the
  total with the game's own valuation (sum of `live_item.bin_value()` over
  `shipping_bins()`, as `sell_shipping_bin_items` does) and includes
  `bin: total, shares: { id: amount }` in `ng`.
- [ ] **No local payout:** in the `ui.menu_opened(Menu.Eod)` handler, while
  online with others, every machine (host included) empties the bin
  inventories before the summary sells them (spike confirms the order). The
  host does this after computing the total.
- [ ] **Pay the share:** after the morning is in place (host: its
  `game.new_day`; guest: snapshot applied), call `ARI.modify_gold(share)`
  once and show a toast with the bin total and the share. Guard against
  paying twice for the same `day`.
- [ ] **Bin contents are already shared** by live sync (the bin is a grid
  object with an inventory). Assert it in `money_bin_split`.

### 4B Shared wallet

- [ ] **Scenarios first:** `wallet_shared_spend` (guest spends, host's
  displayed gold drops by the same amount), `wallet_shared_floor` (two
  simultaneous spends that together exceed the balance: exactly one is
  refused), `wallet_switch_to_shared` (balances add up next morning),
  `wallet_switch_to_separate` (even split next morning), `wallet_rejoin`
  (a player who was offline during shared mode rejoins and sees the shared
  balance, their old personal gold untouched until the mode returns).
- [ ] **Ledger:** host holds `wallet.balance`. Mode and balance are stored in
  the host's mod save data (3.5).
- [ ] **Deltas:** in shared mode every machine's `player.gold_delta` filter
  returns `0` for the local change and sends `gd { amount, seq }` to the host
  (the host applies its own directly). The host applies deltas in arrival
  order; a negative delta that would go below zero is refused with `gx { seq
  }`, and the sender undoes the purchase if possible or shows a notice (see
  risk). The host broadcasts `gb { balance }`; everyone calls
  `ARI.set_gold(balance)` (no hook fires for `set_gold`).
- [ ] **Risk to resolve in the first task of 4B:** a purchase has already
  handed over the item when `modify_gold` runs. Check each spend path for a
  "can afford" test that reads `ARI.gold`; if all do, the local balance is
  authoritative enough and refusals can only come from races. Document the
  result; if races can duplicate value, make spends request-then-apply for
  shop menus only.
- [ ] **Mode switch:** F9 menu (host): "Wallet: separate / shared". Stored as
  pending; applied by the host at its `game.new_day`, announced with `gm {
  mode, balance | shares }`. Personal gold is kept aside (in each farmhand's
  mod save data) while shared mode is on.
- [ ] **Done when:** all `money_*` and `wallet_*` scenarios pass.

## Phase 5: Shared progress and animals

DESIGN.md section 3. Needs: Phase 3.

- [ ] **5.1 Ownership audit (first task, a document change):** for each item
  below, confirm in `SaveGame.gml:63-246` and `LoadGame.gml` which save
  section holds it, and add a table "Shared state: where it lives" to the
  facts section. Do not sync anything not in that table.
- [ ] **5.2 Museum.** Scenario `progress_museum`: guest donates; the host's
  museum shows it; both got the set reward if it completed a set; survives a
  night. State: `MUSEUM_PROGRESS` (in `gamedata.museum_progress`) plus world
  facts `museum_donated_*`. Hook `museum.donate_item` (ctx `{ item_id }`,
  fires before registration) -> send `mu { item }`; receivers call
  `register_item_to_museum(item_id)` (`scripts/Museum.gml:106`). Add the
  museum array to the snapshot header. Rewards for others: grant through the
  game's reward function found in the audit, once per player per set.
- [ ] **5.3 Mine depth.** Scenario `progress_mine_depth`. Send `md { level }`
  when `MAXIMUM_REACHED_DUNGEON_LEVEL` grows (poll once a second); receivers
  take the max. Already in the snapshot.
- [ ] **5.4 World unlocks.** Scenario `progress_unlock`: set an unlock fact
  on the host; the guest's `world_mod_enabled(...)` for that area becomes
  true after the next snapshot and the area is open. Build the key list at
  runtime from `WORLD_MODS[*].requirements` (`scripts/WorldMod.gml:21`):
  collect the world-fact names and scene names those requirements read. Add
  to the snapshot: those facts (from `T2R.read_world()`) and those scene
  names if present in the host's `scene_history`. Apply on the guest with
  `T2R.write` + `T2R.update()` and by adding to its scene history. Never copy
  facts that are personal (relationship, dating, spouse); keep an explicit
  deny list and a unit test for the filter.
- [ ] **5.5 Farm animals.** Scenario `animals_care`: guest pets and feeds an
  animal; the host's animal shows petted/fed; produce next morning matches on
  both. Animals live on building nodes (`building.stable`), which live sync
  skips. Add message `an { root, idx, pat, eaten, outside, hearts, prod }`
  sent on the `animal.pet` hook and from a once-a-second check of the
  animals in the current building; apply to the matching `Animal` struct on
  every machine. The host's state wins each morning through the snapshot.
- [ ] **5.6 Farm expansion and house upgrades:** already in the snapshot;
  add scenario `progress_farm_expand` to pin it.
- [ ] **Done when:** scenarios pass; README "What works" gains only what
  these scenarios prove.

## Phase 6: Dropped items and chest locking

DESIGN.md section 7. Needs: Phase 3.

- [ ] **6.1 Scenarios first:** `items_drop_visible` (guest drops; host sees
  an item at that spot), `items_pickup_once` (both players next to one item
  trigger pickup in the same second; exactly one inventory gains it and the
  item is gone for both), `items_leave_room` (an item dropped in a room
  nobody is in is there when a player enters), `chest_lock` (guest opens a
  chest; the host's attempt is refused with the guest's name; after the guest
  closes it the host can open it and sees the guest's change).
- [ ] **6.2 Item identity.** Each dropped stack gets an id `<peer>-<counter>`
  stored on the `obj_item` instance (`mt_gid`). Hook `items.dropped` (ctx `{
  items, x, y, ... }`, fires before the items spawn) -> next tick, tag the new
  untagged `obj_item` instances near `x, y` and send `id { gid, g, x, y,
  items:[serialized] }` (serialize with each live item's own `serialize()`).
  Receivers in that location spawn an `obj_item` with that `gid`; receivers
  elsewhere append to that grid's `lost_items` list so it appears on entry
  (`scripts/GameplaySystems/Items/Items.gml:687-698`).
- [ ] **6.3 Pickup.** A tagged item that disappears locally (per-tick check
  of known gids in the room) sends `ip { gid }` to the host. The host keeps
  the set of live gids: first request wins and is broadcast as `ix { gid, by
  }`; a loser gets `ix` naming someone else and must give the item back
  (remove it from the inventory it just entered). Others despawn the item.
  Items the game spawns itself (tree drops, monster loot) stay local and
  untagged.
- [ ] **6.4 Chest lock.** Storage chests and the shipping bin open
  `Menu.Storage`. On `ui.menu_opened` with that kind, identify the node (from
  the menu's fields; record the field in the facts section) and send `cl {
  g, x, y, on:1 }` to the host; the host grants or denies (`cg`/`cd`). Until
  granted, and on deny, close the menu and toast "In use by <name>". Send
  `on:0` on `ui.menu_closed`. The host releases a lock when its holder
  leaves. The chest's contents then travel by the existing object sync when
  the menu closes; force a signature check of that node on close so it is
  immediate.
- [ ] **Done when:** scenarios pass.

## Phase 7: Scenes and festivals

DESIGN.md sections 4, 5, 7. Needs: Phases 1, 2, 6.

- [ ] **7.1 Scenarios first:** `scene_hides_player` (guest runs a short
  scene; the host's ghost of the guest is hidden during it and back after),
  `scene_clock_runs` (session time advances during the guest's scene),
  `scene_items_survive` (a tagged dropped item in the room is still there for
  both after the guest's scene), `scene_ends_day_holds` (a scene with
  `ends_day` puts that player in the held state).
- [ ] **7.2 Hidden flag.** Add `q:1` to the pose while
  `has_flag(PAUSE_STATUS, PauseStatus.CUTSCENE)`; receivers do not draw that
  ghost.
- [ ] **7.3 Loose items.** A scene start destroys every `obj_item` in the
  room after storing them as lost (`Mist.gml:364-420`). After the scene ends
  locally, re-create tagged items from the host's live gid list for that
  location (request `il { g }` -> `id` messages).
- [ ] **7.4 Day-ending scenes** need no new code beyond Phase 2.5; the
  scenario pins it. Festivals use the same rules as any location.
- [ ] **Done when:** scenarios pass.

## Phase 8: Mines

DESIGN.md section 8. Needs: Phase 3. Experimental: ship behind a host
setting until its scenarios are stable.

- [ ] **8.1 Spike first** `spike_mine_seed`: on `dungeon.runner_created` and
  `dungeon.room_build_begin` call `random_set_seed(<fixed>)`; build the same
  floor twice in one game and once on a second instance; compare digests of
  the dungeon grid. Record whether the itinerary (built before
  `runner_created` in `create_dungeon_itinerary`,
  `scripts/GameplaySystems/Dungeon/enter_dungeon.gml:90`) is also equal; if
  not, the floor's room id must be sent by the first player on that floor.
- [ ] **8.2 Scenarios first:** `mine_same_floor` (both enter floor N; digests
  equal; they see each other), `mine_rock_shared` (one breaks a rock; gone for
  both), `mine_different_floors` (players on different floors do not see each
  other or each other's changes).
- [ ] **8.3 Seeding.** Session seed chosen by the host per day, sent in `tm`.
  Floor seed = session seed + floor number. Seed at `room_build_begin`, and
  call `randomize()` after `dungeon.floor_built` so play is not predictable.
- [ ] **8.4 Location key.** `mt_location_key` returns `dng:<floor>` in a
  dungeon room instead of the per-player key; `mt_sync_grid_shared` allows
  the dungeon grid when keys match; grid references in `wo/wd/wt` carry the
  floor.
- [ ] **Done when:** scenarios pass; the limitation (monsters local) is in
  README.

---

## Verified game facts

Checked against game v1.0.8 scripts. Paths are under `assets/gml/`.

### Day end
- Bed: `scripts/GameplaySystems/Data/Grid/GridActions/Interact.gml`.
  `interact(node)` at `:90`; bed interactable test at `:72`
  (`node.prototype.bed_kind != undefined && requirements_pass(Requirement.Sleep)`);
  popup `popup_creator("misc_local/bed", "misc_local/go_to_sleep")` at `:697`;
  on yes sets `ARI.last_bed_used` (`:708`) and calls
  `MIST.request_scene("sleep")` (`:724`).
- Scene end: `scripts/GameplaySystems/Mist/Mist.gml` `clean_up_scene` (`:603`);
  if the scene has `ends_day` (`:926`) it sets `ARI.end_of_day_status` when
  unset and calls `end_day(true, ...)`.
- `end_day(spawn_eod_menu=true, held_point_of_interest)`:
  `scripts/GameplaySystems/Cycle/EndDay.gml:2`. Runs `MIST.on_end_day()`,
  feeds animals, applies sprinklers, then spawns `Menu.Eod` (`:96`) once no
  scene is running. Every day-ending path goes through it. There is no hook
  that can cancel it.
- Summary: `scripts/UI/Anchor/Menus/EodMenu.gml`. `init` (`:28`) stops the
  clock (`:60`), sets `ARI.end_of_day_sequence` (`:70`), sells the bin
  (`:96`). `end_sequence` (`:938`) calls `new_day()` (`:946`), `save_game`
  (`:951`), then wakes the player.
- `new_day()`: `scripts/GameplaySystems/Cycle/NewDay.gml:3` =
  `new_day_non_grid()` (`:14`, calendar, `CLOCK = new Clock()` at `:49`,
  weather from forecast, request board, restores stamina/health/mana) +
  `new_day_grid()` (`:230`, seeded at `:232` with `Game.unique_identifier +
  get_days(CALENDAR.time)`).
- Passing out: `scripts/Player/pass_out.gml:1` (`pass_out(faint)` -> zero
  stamina -> `end_day()`). 2:00 check: `objects/characters/obj_ari.gml:1383`
  `should_faint` (fires at `CLOCK.time >= hours(26)` unless
  `ARI.end_of_day_status` is set or a room change is running). Death:
  `should_die` (`:1421`) runs the `dying` scene (`:1461`), which ends the day.
- Hooks: `player.pass_out` fires right after `end_day()` inside `pass_out`;
  `player.died` fires right after the dying scene starts; `game.new_day`
  fires inside `new_day()` before the autosave; `ui.menu_opened` ctx is
  `{ menu, kind }` and fires right after the menu is spawned.

### Time
- `scripts/GameplaySystems/TimeSeasons/Clock.gml`: `jump(time)` (`:15`, also
  moves townspeople and the pet, refuses to go backwards), `set_time` (`:41`),
  `update` (`:56`): `side_buffer += GAME_SECONDS_PER_FRAME * !game_paused() *
  !time_stopped` (`:58`). The `clock.time_advance` filter replaces that
  per-frame amount.
- Pause flags (`scripts/Pause.gml`): `CUTSCENE`, `WINDOW`, `MENU`;
  `game_paused()` is true if any is set. Menus set `MENU` only when their
  definition says `pause = "main"`.
- Callers of `CLOCK.jump` in normal play: timed recipes
  (`scripts/GameplaySystems/Recipe.gml`), scene `end_time_jump`
  (`Mist.gml:944`), oversleep in `wake_up_sequence`
  (`scripts/GameplaySystems/Player/AriUtils.gml`). The other callers are the
  debug console and the game's own test suite.
- A new `Clock` is created every morning, so anything wrapped on `CLOCK` must
  be re-applied.

### Money
- `ARI.gold`; `set_gold` (`Ari.gml:349`), `modify_gold` (`:362`, fires
  `player.gold_delta`, value = signed delta, return `0` to cancel).
  `serialize_stats` (`:603`) writes gold, essence, renown, health, stamina.
- Shipping: `shipping_bins()` (`Ari.gml:1156`), `sell_shipping_bin_items()`
  (`EodMenu.gml:975`).

### Saves
- `save_game(path)`: `scripts/Serialization/SaveGame.gml:1`; sections written
  at `:262-268`: `header`, `gamedata` (calendar, clock, weather, world facts,
  scene history, museum, mine depth, farm expansion, pet), `player`
  (character, inventory, stats, perks, recipes, house decor and upgrade,
  marriage), `npcs` (heart points and state per townsperson), `quests`,
  `game_stats`, `date_photos`, plus one file per location grid and the farm
  terrain buffer. Hooks: `game.save_guard` (veto), `save.game_saving`.
- Path: `exact_save_path(game_ident, is_manual, save_ident)`
  (`scripts/Serialization/Serde/SerdeUtils.gml:8`) ->
  `saves/game-<ident>-autosave.sav`.
- Identifier: `LoadState.New` picks `irandom(I32_MAX)`
  (`scripts/Serialization/LoadState.gml:15`); `Game.unique_identifier` takes
  it from the load state.
- Loading replaces the whole game from one file; there is no function that
  loads only the player section.
- Entering a game from code: `Setup.enter_game(LoadState.New({...}))` or
  `Setup.enter_game(LoadState.Load(bundle))` (see `MtDev.gml`
  `mt_dev_autostart`, which already does both).

### Shared progress
- Museum: `register_item_to_museum(item_id)` (`scripts/Museum.gml:106`),
  `donate_item_to_museum` (`:112`, fires `museum.donate_item` first).
- Mines: `MAXIMUM_REACHED_DUNGEON_LEVEL`; `enter_dungeon(start_floor, ...)`
  (`scripts/GameplaySystems/Dungeon/enter_dungeon.gml:2`);
  `create_dungeon_itinerary` (`:90`) and floor building use unseeded random
  numbers. Hook order: `dungeon.runner_created`, `dungeon.floor_enter`,
  `dungeon.room_build_begin`, build, `dungeon.floor_built`.
- Daily generation seeded by the game identifier: `new_day_grid`, request
  board, shop stock. Unseeded: weather forecast (synced by the host), lost and
  found, wild animals.
- Dropped items are not saved; they are kept per grid in `lost_items` between
  visits.
- `object.chest_open_guard` and `items.chest_opened` are about treasure
  chests and chest items, not storage chests. Storage uses `Menu.Storage`.

### Spike results

_(Filled in by Phase 0.5.)_

## Message reference

Game-to-game messages (`t`), current and planned. Keep this table in step
with the code; `tools/lint-gml.py` checks that every type has a handler.

| t | From -> to | Reliable | Phase | Meaning |
| --- | --- | --- | --- | --- |
| `hi` | any -> all | yes | shipped | name, farm, appearance |
| `p` | any -> all | no | shipped (+`q` in 7) | pose |
| `ps` | any -> all | yes | shipped | held item, tool, attachment |
| `tm` | host -> all | yes | shipped, changed in 1 and 8 | calendar, session time, pause, weather |
| `wreq` | guest -> host | yes | shipped | ask for a snapshot |
| `wo` `wd` `wt` | any -> all | yes | shipped | object put, object removed, soil cells |
| `nr` | any -> host | yes | 2 | ready / not ready / held |
| `ns` | host -> all | yes | 2 | ready list |
| `ng` | host -> all | yes | 2 (+bin in 4) | night starts |
| `gd` `gx` `gb` `gm` | see 4B | yes | 4 | shared wallet |
| `mu` `md` | any -> all | yes | 5 | museum donation, mine depth |
| `an` | any -> all | yes | 5 | animal care state |
| `id` `ip` `ix` `il` | see 6 | yes | 6 | dropped items |
| `cl` `cg` `cd` | see 6 | yes | 6 | chest lock |

System messages from the companion (`from = -1`): `welcome`, `join`, `leave`,
`bye`, `stat`, `blob`.

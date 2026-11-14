// Mistria Together - MtDev.gml: developer / test automation hooks.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Completely inert unless the game is started with the environment variable
// MISTRIA_TOGETHER_DEV set. The end-to-end test rig (tools/rig) uses it to
// start a game without touching the UI, to drive the player around, and to
// read back what the mod sees, so two real game instances can be tested
// against each other headlessly.
//
//   MISTRIA_TOGETHER_DEV=new|continue   start a new game / load the latest save
//   MISTRIA_TOGETHER_DEV=menu-*         leave the title open on a menu page
//   MISTRIA_TOGETHER_DEV_NAME=<name>    character name for a new game
//   MISTRIA_TOGETHER_DEV_LOOK=<n>       vary the default look (hair / outfit colour)
//
// While enabled the mod also executes commands appended to
// <ipc dir>/dev_cmd_<n>.json and dumps its state to <ipc dir>/dev_state.json.

function mt_dev_state() {
    if (global[$ "__mt_dev"] == undefined) {
        var _mode = environment_get_variable("MISTRIA_TOGETHER_DEV");
        global.__mt_dev = {
            enabled: is_string(_mode) && _mode != "",
            mode: _mode,
            started: false,
            cmd_seq: 0,
            move: undefined,
            log: [],
            trace: [],
        };
    }
    return global.__mt_dev;
}

function mt_dev_on_title(_ctx) {
    var _dev = mt_dev_state();
    if (!_dev.enabled) { return; }
    if (_dev.mode == "title") {
        if (!_dev[$ "title_loop"]) {
            _dev.title_loop = true;
            new_chain().join(LinkId.Timer, 30).append(LinkId.Function, mt_dev_title_loop);
        }
        return;
    }
    if (_dev.started) { return; }
    if (string_copy(_dev.mode, 1, 5) == "menu-") {
        _dev.started = true;
        return;
    }
    _dev.started = true;
    new_chain()
        .join(LinkId.Timer, 30)
        .append(LinkId.Function, mt_dev_autostart);
}

function mt_dev_autostart() {
    var _dev = mt_dev_state();
    try {
        var _menu = ANCHOR.get_menu(Menu.Title);
        if (_menu != undefined) { _menu.close(); }
    } catch (_e) {}

    if (_dev.mode == "continue") {
        var _saves = Setup.save_manager.get_saves_ordered();
        if (array_length(_saves) > 0) {
            var _bundle = Setup.save_manager.manifest.get(_saves[0]);
            var _state = LoadState.Load(_bundle);
            patch_save(_state.loader);
            Setup.enter_game(_state);
            return;
        }
    }

    global.__story_enabled = false;     // skip the prologue
    var _name = environment_get_variable("MISTRIA_TOGETHER_DEV_NAME");
    if (!is_string(_name) || _name == "") { _name = "Tester"; }
    var _preset = create_default_player_animation_assets();
    var _look = environment_get_variable("MISTRIA_TOGETHER_DEV_LOOK");
    if (is_string(_look) && _look != "") {
        var _n = real(_look);
        for (var _i = 0; _i < _preset.assets.count(); _i++) {
            var _asset = _preset.assets.get(_i);
            if (_i > 0) { _asset.lut_index = 1 + ((_asset.lut_index + _n * 7) % 12); }
        }
        _preset.skin_tone = _n % 6;
    }
    Setup.enter_game(LoadState.New({
        name: _name,
        farm_name: _name + " Farm",
        pronouns: default_pronouns(),
        presets: List(_preset),
        preset_index_selected: 0,
        birthday: DEFAULT_ARI_BIRTHDAY,
    }));
}

function mt_dev_note(_text) {
    var _dev = mt_dev_state();
    if (!_dev.enabled) { return; }
    array_push(_dev.log, string(_text));
    while (array_length(_dev.log) > 40) { array_delete(_dev.log, 0, 1); }
}

// Runs one dev command and returns its result (a plain struct or undefined).
function mt_dev_run(_cmd) {
    var _dev = mt_dev_state();
    var _val = undefined;
    switch (_cmd[$ "cmd"]) {
        case "tp":
            ari_teleport_to_room(string_to_location_id(_cmd.room), _cmd.x, _cmd.y);
            break;
        case "pos":
            obj_ari.x = _cmd.x;
            obj_ari.y = _cmd.y;
            break;
        case "move":
            // Glide the player by (dx, dy) pixels per frame for `frames` frames.
            _dev.move = { dx: _cmd.dx, dy: _cmd.dy, frames: _cmd.frames };
            break;
        case "digest":
            _val = { lines: mt_sync_digest(_cmd[$ "scope"] ?? "near", _cmd[$ "radius"] ?? 14) };
            break;
        case "clock":
            // set: move session time (host) or the local clock (forward only);
            // jump: call CLOCK.jump as the game would (wrapped while online);
            // st: set session time directly on the host.
            var _w = mt_world_state();
            if (_cmd[$ "set"] != undefined) {
                if (mt_is_host() && _w.st_active) { _w.st = _cmd.set; _w.time_sent_frame = -100000; }
                else { mt_clock_jump_real(_cmd.set); }
            }
            if (_cmd[$ "jump"] != undefined) { CLOCK.jump(_cmd.jump); }
            _val = {
                clk: CLOCK.time, cal: CALENDAR.time, paused: game_paused(),
                st: floor(_w.st), st_paused: mt_world_paused_by_host(), driven: mt_world_clock_driven(),
                mpd: MINUTES_PER_DAY,
            };
            break;
        case "bed":
            // sleep: lie down in the first bed of this home (as the bed popup's
            // Sleep button does); get_up: cancel.
            if (_cmd.action == "get_up") { mt_night_get_up(); break; }
            var _bed = undefined;
            for (var _bi = 0; _bi < GRID.node_len && _bed == undefined; _bi++) {
                if (GRID.node_object_id[_bi] == undefined) { continue; }
                var _bp = GRID.node_parent[_bi];
                if (_bp.prototype.bed_kind != undefined) { _bed = _bp; }
            }
            if (_bed == undefined) { throw "no bed in this room"; }
            mt_night_go_bed(_bed);
            break;
        case "faint":
            pass_out(true);
            break;
        case "summary_next":
            // Tap the overnight summary's next-day button if it can be used.
            var _eod = ANCHOR.get_menu(Menu.Eod);
            if (_eod == undefined || _eod[$ "next_day_button"] == undefined) { _val = { tapped: false, why: "no button" }; break; }
            if (!_eod.next_day_button.is_unlocked()) { _val = { tapped: false, why: "locked" }; break; }
            ANCHOR.tap_node(_eod.next_day_button);
            _val = { tapped: true };
            break;
        case "night_state":
            _val = mt_night_dev_state();
            break;
        case "title_join":
            mt_farm_begin_join(_cmd.addr, _cmd[$ "name"] ?? "", true);
            break;
        case "title_load":
            // What the normal load menu does: continue the newest save.
            var _tl = Setup.save_manager.get_saves_ordered();
            var _tb = Setup.save_manager.manifest.get(_tl[0]);
            var _ts = LoadState.Load(_tb);
            patch_save(_ts.loader);
            mt_farm_close_title();
            Setup.enter_game(_ts);
            break;
        case "quit_to_title":
            Game.exit_to_menu();
            break;
        case "save":
            var _sp = exact_save_path(Game.unique_identifier, false);
            ARI.save_position = player_wake_position();
            save_game(_sp);
            _val = { path: _sp, exists: file_exists(_sp) };
            break;
        case "save_info":
            _val = { ident: mt_farm_id(), tag: mt_farm_state().tag, adopted: mt_sync_state().adopted, name: string(ARI.name), gold: ARI.gold };
            break;
        case "guard_check":
            var _gs = mt_sync_state();
            var _was = _gs.adopted;
            _gs.adopted = _cmd.adopted == true;
            _val = { result: mt_farm_save_guard() };
            _gs.adopted = _was;
            break;
        case "bin_put":
            shipping_bins().first().inventory.add(ItemId.Turnip, _cmd[$ "count"] ?? 1);
            break;
        case "bin_info":
            var _bn = shipping_bins().first();
            var _bx = _bn.top_left_x;
            var _by = _bn.top_left_y;
            var _in_grid = _bx >= 0 && _by >= 0 && _bx < GRID.dims.x && _by < GRID.dims.y && GRID.node_parent[GRID.node_index_for_cell(_bx, _by)] == _bn;
            var _bs = mt_sync_state();
            _val = {
                x: _bx, y: _by, in_grid: _in_grid, bins: shipping_bins().count(), storage: STORAGE_NODES.count(),
                cat: string(object_id_to_object_category(_bn.object_id)), synced: mt_sync_object_synced(_bn.object_id),
                known: _bs.sigs[$ (string(_bx) + ":" + string(_by))] != undefined, grid_shared: mt_sync_grid_shared(GRID),
                tracking: _bs.grid == GRID, player: [floor(obj_ari.x / OBJECT_CELL_SIZE), floor(obj_ari.y / OBJECT_CELL_SIZE)],
                adopted: _bs.adopted, sent: _bs.sent, received: _bs.received,
            };
            break;
        case "bin_value":
            _val = { value: mt_money_bin_total() };
            break;
        case "gold":
            if (_cmd[$ "set"] != undefined) { ARI.set_gold(_cmd.set); }
            if (_cmd[$ "add"] != undefined) { ARI.modify_gold(_cmd.add); }
            _val = { gold: ARI.gold };
            break;
        case "host_pause":
            mt_world_set_pause(_cmd.on == true);
            break;
        case "menu_open":
            // Freeze only this game, as an open menu does.
            PAUSE_STATUS = PAUSE_STATUS | PauseStatus.MENU;
            break;
        case "menu_close":
            PAUSE_STATUS = remove_flag(PAUSE_STATUS, PauseStatus.MENU);
            break;
        case "setmpd":
            MINUTES_PER_DAY = _cmd.value;
            break;
        case "gold_get":
            _val = { gold: ARI.gold };
            break;
        case "time":
            CLOCK.jump(_cmd.clk);
            break;
        case "pause":
            PAUSE_STATUS = _cmd.on ? set_flag(PAUSE_STATUS, PauseStatus.MENU) : remove_flag(PAUSE_STATUS, PauseStatus.MENU);
            break;
        case "weather":
            WEATHER.set_weather(_cmd.w);
            break;
        case "menu":
            // Drive the Multiplayer menu and its views in the isolated rig.
            if (_cmd.action == "open") { mt_menu_open(); }
            else if (_cmd.action == "more") { mt_menu_join_menu(); }
            else if (_cmd.action == "connections") { mt_menu_nearby(); }
            else if (_cmd.action == "friends") { mt_menu_friends(); }
            else if (_cmd.action == "settings") { mt_menu_settings(); }
            else if (_cmd.action == "pick") { mt_menu_nearby(); }
            else if (_cmd.action == "type") { mt_menu_direct_join(); }
            else if (_cmd.action == "host") { mt_menu_on_host(); }
            else if (_cmd.action == "join") { mt_menu_set("join", _cmd.addr); }
            else if (_cmd.action == "f9join") { mt_menu_join_address(_cmd.addr); }
            else if (_cmd.action == "off") { mt_menu_on_disconnect(); }
            else if (_cmd.action == "joinlan") {
                var _dl = mt_menu_link();
                if (_dl == undefined || !is_array(_dl[$ "lan"]) || array_length(_dl.lan) == 0) { throw "no game found on the network"; }
                mt_menu_set("join", string(_dl.lan[0].addr));
            }
            break;
        case "trace":
            // Dump and clear the motion trace.
            mt_ipc_write("dev_trace.json", json_stringify({ trace: _dev.trace }));
            _dev.trace = [];
            break;
        case "quit":
            game_end();
            break;
        default:
            _val = mt_sync_dev_command(_cmd);
            break;
    }
    return _val;
}

// Run the next queued command file, if any (in the world every 6 frames, on
// the title screen from mt_dev_title_loop).
function mt_dev_poll_commands() {
    var _dev = mt_dev_state();
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { return; }
    var _path = _rt.dir + "/dev_cmd_" + string(_dev.cmd_seq) + ".json";
    if (!file_exists(_path)) { return; }
    var _cmd = try_read_json_file(_path, undefined, false);
    _dev.cmd_seq += 1;
    if (!is_struct(_cmd)) { return; }
    var _res = { n: _dev.cmd_seq - 1, ok: true, error: "", value: undefined };
    try {
        _res.value = mt_dev_run(_cmd);
        mt_dev_note("ok " + string(_cmd[$ "cmd"]));
    } catch (_e) {
        _res.ok = false;
        _res.error = string(_e);
        mt_dev_note("FAILED " + string(_cmd[$ "cmd"]) + ": " + string(_e));
        mt_warn("dev command failed: " + string(_e));
    }
    try { mt_ipc_write("dev_res_" + string(_res.n) + ".json", json_stringify(_res)); }
    catch (_e2) { mt_warn("dev result not written: " + string(_e2)); }
}

// MISTRIA_TOGETHER_DEV=title: stay on the title screen and serve commands
// there (the mod's tick does not run until a save is loaded).
function mt_dev_title_loop() {
    var _dev = mt_dev_state();
    var _rt = __mt_rt();
    if (mt_in_world()) { _dev.title_loop = false; return; }
    try {
        if (_rt.dir != undefined) {
            mt_dev_poll_commands();
            var _idents = [];
            var _keys = Setup.save_manager.manifest.keys();
            for (var _i = 0; _i < array_length(_keys); _i++) {
                array_push(_idents, string(Setup.save_manager.manifest.get(_keys[_i]).game_ident));
            }
            mt_ipc_write("dev_state.json", json_stringify({
                title: true, in_world: false, online: false, cmd_seq: _dev.cmd_seq,
                log: _dev.log, saves: _idents, notice: mt_farm_state().notice, notice_shown: mt_farm_state().notices_shown,
                join: mt_farm_state().join != undefined,
            }));
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_dev_title", MT_MOD, "dev title loop: " + string(_e));
    }
    new_chain()
        .join(LinkId.Timer, 10)
        .append(LinkId.Function, mt_dev_title_loop);
}

function mt_dev_tick() {
    var _dev = mt_dev_state();
    if (!_dev.enabled) { return; }
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { return; }

    if (_dev.move != undefined && instance_exists(obj_ari)) {
        obj_ari.x += _dev.move.dx;
        obj_ari.y += _dev.move.dy;
        _dev.move.frames -= 1;
        if (_dev.move.frames <= 0) { _dev.move = undefined; }
    }

    // Per-frame trace of the first remote player, to measure how smoothly
    // it moves on this side.
    if (array_length(_rt.peer_ids) > 0) {
        var _tp = _rt.peers[$ string(_rt.peer_ids[0])];
        if (_tp != undefined && _tp.inst != undefined && instance_exists(_tp.inst)) {
            array_push(_dev.trace, [_rt.frame, _tp.inst.x, _tp.inst.y, _tp.inst.mt_anim, array_length(_tp.buf)]);
            while (array_length(_dev.trace) > 400) { array_delete(_dev.trace, 0, 1); }
        }
    }

    if (_rt.frame % 6 == 0) { mt_dev_poll_commands(); }

    if (_rt.frame % 15 == 0) {
        var _peers = [];
        for (var _i = 0; _i < array_length(_rt.peer_ids); _i++) {
            var _peer = _rt.peers[$ string(_rt.peer_ids[_i])];
            if (_peer == undefined) { continue; }
            var _ghost = undefined;
            if (_peer.inst != undefined && instance_exists(_peer.inst)) {
                _ghost = {
                    x: _peer.inst.x, y: _peer.inst.y,
                    anim: _peer.inst.mt_anim, cardinal: _peer.inst.cardinal,
                    look: _peer.inst.mt_look_key != "",
                };
            }
            array_push(_peers, {
                id: _peer.id, name: _peer.name, loc: _peer.loc, ping: _peer.ping,
                buf: array_length(_peer.buf), has_look: _peer.look != undefined, ghost: _ghost,
            });
        }
        var _state = {
            frame: _rt.frame,
            cmd_seq: _dev.cmd_seq,
            link_alive: _rt.link_alive,
            link_state: _rt.link_state,
            online: _rt.online,
            self_id: _rt.self_id,
            host_id: _rt.host_id,
            in_world: _rt.in_world,
            peers: _peers,
            log: _dev.log,
            fps: fps_average(),
        };
        if (_rt.in_world) {
            _state.name = string(ARI.name);
            _state.loc = mt_location_key();
            _state.x = obj_ari.x;
            _state.y = obj_ari.y;
            _state.clk = CLOCK.time;
            _state.cal = CALENDAR.time;
            _state.weather = WEATHER.weather;
            _state.paused = game_paused();
            _state.sync = mt_sync_dev_state();
        }
        _state.night = mt_night_dev_state();
        _state.money = mt_money_dev_state();
        mt_ipc_write("dev_state.json", json_stringify(_state));
    }
}

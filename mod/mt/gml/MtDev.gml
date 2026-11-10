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
    if (!_dev.enabled || _dev.started || _dev.mode == "title") { return; }
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

function mt_dev_run(_cmd) {
    var _dev = mt_dev_state();
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
            else if (_cmd.action == "more") { mt_menu_more(); }
            else if (_cmd.action == "connections") { mt_menu_connections(); }
            else if (_cmd.action == "friends") { mt_menu_friends(); }
            else if (_cmd.action == "settings") { mt_menu_settings(); }
            else if (_cmd.action == "pick") { mt_menu_on_join(0); }
            else if (_cmd.action == "type") { mt_menu_on_join(99); }
            else if (_cmd.action == "host") { mt_menu_on_host(); }
            else if (_cmd.action == "join") { mt_menu_join_address(_cmd.addr); }
            else if (_cmd.action == "off") { mt_menu_on_disconnect(); }
            else if (_cmd.action == "joinlan") {
                var _dl = mt_menu_link();
                if (_dl == undefined || !is_array(_dl[$ "lan"]) || array_length(_dl.lan) == 0) { throw "no game found on the network"; }
                mt_menu_join_address(string(_dl.lan[0].addr));
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
            mt_sync_dev_command(_cmd);
            break;
    }
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

    if (_rt.frame % 6 == 0) {
        var _path = _rt.dir + "/dev_cmd_" + string(_dev.cmd_seq) + ".json";
        if (file_exists(_path)) {
            var _cmd = try_read_json_file(_path, undefined, false);
            _dev.cmd_seq += 1;
            if (is_struct(_cmd)) {
                try {
                    mt_dev_run(_cmd);
                    mt_dev_note("ok " + string(_cmd[$ "cmd"]));
                } catch (_e) {
                    mt_dev_note("FAILED " + string(_cmd[$ "cmd"]) + ": " + string(_e));
                    mt_warn("dev command failed: " + string(_e));
                }
            }
        }
    }

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
        mt_ipc_write("dev_state.json", json_stringify(_state));
    }
}

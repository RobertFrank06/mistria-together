// Mistria Together - MtFarm.gml: farmhand saves and the title-screen Join flow.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A farm is identified by the host's game identifier (the <ident> in
// saves/game-<ident>-autosave.sav). A farmhand's character is a local save
// with the SAME identifier, tagged by this mod as a farmhand save (a sidecar
// written through MMAPI's modsave). Joining happens from the title screen:
// the companion is asked about the farm ("query"), then the farmhand save is
// continued or created and the game is entered with that identifier. Solo
// saves are never touched.

function mt_farm_state() {
    var _rt = __mt_rt();
    if (_rt[$ "farm"] == undefined) {
        _rt.farm = {
            tag: undefined,        // the loaded save's tag ({ role, farm_id, ... })
            pending: undefined,    // tag for a farmhand save about to be created
            joining: "",           // farm id of the join in progress
            join: undefined,       // { addr, name, polls } while asking a host
            notice: "",            // shown once the title screen is back
            registered: false,
            notices_shown: 0,
        };
    }
    return _rt.farm;
}

function mt_farm_id() {
    return string(Game.unique_identifier);
}

function mt_farm_is_farmhand() {
    var _f = mt_farm_state();
    var _t = is_struct(_f.tag) ? _f.tag : _f.pending;
    return is_struct(_t) && _t[$ "role"] == "farmhand";
}

// The farm this save is tagged for (a farmhand save only), else "".
function mt_farm_tag_id() {
    var _f = mt_farm_state();
    var _t = is_struct(_f.tag) ? _f.tag : _f.pending;
    return is_struct(_t) ? string(_t[$ "farm_id"]) : "";
}

function mt_farm_register() {
    var _f = mt_farm_state();
    if (_f.registered) { return; }
    _f.registered = true;
    mmapi_modsave_register(MT_MOD, mt_farm_save_collect, mt_farm_save_apply);
}

// --- the tag in the save's sidecar ------------------------------------------

function mt_farm_save_collect() {
    var _f = mt_farm_state();
    if (is_struct(_f.tag)) {
        var _p = mt_money_state().personal;
        if (_p != undefined) { _f.tag.personal = _p; }
        return _f.tag;
    }
    if (is_struct(_f.pending)) {
        _f.tag = _f.pending;
        _f.pending = undefined;
        return _f.tag;
    }
    if (mt_is_host()) {
        return { v: 1, role: "host", farm_id: mt_farm_id(), farm_name: string(ARI.farm_name), host_name: string(ARI.name), wallet: mt_money_state().mode };
    }
    return undefined;
}

function mt_farm_save_apply(_data) {
    var _f = mt_farm_state();
    if (is_struct(_data)) { _f.tag = _data; }
    else { _f.tag = _f.pending; }
    // The host's wallet mode comes back with its farm.
    var _m = mt_money_state();
    _m.mode = (is_struct(_data) && _data[$ "role"] == "host" && _data[$ "wallet"] == "shared") ? "shared" : "separate";
    _m.personal = (is_struct(_data) && _data[$ "personal"] != undefined) ? _data.personal : undefined;
    _f.pending = undefined;
}

// The tag stored for a farm id on this machine, read without loading it.
function mt_farm_read_tag(_ident) {
    try {
        var _path = mmapi_modsave_file(MT_MOD, string(_ident));
        if (file_exists(_path)) {
            var _data = try_read_json_file(_path, undefined, false);
            if (is_struct(_data)) { return _data; }
        }
    } catch (_e) {}
    return undefined;
}

// The local save (manifest key) for a farm id, or undefined.
function mt_farm_find_save(_ident) {
    var _keys = Setup.save_manager.manifest.keys();
    var _best = undefined;
    var _best_time = -1;
    for (var _i = 0; _i < array_length(_keys); _i++) {
        var _b = Setup.save_manager.manifest.get(_keys[_i]);
        if (_b.game_ident != _ident) { continue; }
        var _t = _b.info[$ "last_played"] ?? 0;
        if (_t >= _best_time) { _best = _keys[_i]; _best_time = _t; }
    }
    return _best;
}

// --- join flow (title screen) --------------------------------------------------

// Ask the host about its farm; the rest happens in mt_farm_poll.
function mt_farm_begin_join(_addr, _name = "", _auto = false) {
    var _f = mt_farm_state();
    _addr = string_trim(string(_addr));
    if (_addr == "") { return; }
    if (_f.join != undefined) { return; }
    _f.join = { addr: _addr, name: _name, auto: _auto, polls: 0 };
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { mt_ipc_init(); }
    _rt.control_seq += 1;
    mt_ipc_write("control.json", json_stringify({
        seq: _rt.control_seq, nonce: irandom(999999999),
        mode: "query", addr: _addr, port: MT_DEFAULT_PORT, password: mt_config().password,
    }));
    mt_log("asking " + _addr + " about its farm");
    mt_farm_arm_poll();
}

function mt_farm_arm_poll() {
    new_chain()
        .join(LinkId.Timer, 20)
        .append(LinkId.Function, mt_farm_poll);
}

function mt_farm_poll() {
    var _f = mt_farm_state();
    var _j = _f.join;
    if (_j == undefined) { return; }
    _j.polls += 1;
    try {
        var _link = mt_menu_link();
        if (_link != undefined && _link[$ "info_addr"] == _j.addr) {
            if (is_struct(_link[$ "info"])) {
                _f.join = undefined;
                mt_farm_on_info(_j, _link.info);
                return;
            }
            var _err = _link[$ "info_error"];
            if (is_string(_err) && _err != "") {
                _f.join = undefined;
                mt_menu_notice("Multiplayer", "Cannot join " + _j.addr + ": " + _err);
                return;
            }
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_farm_poll", MT_MOD, "join poll failed: " + string(_e));
    }
    if (_j.polls > 40) {
        _f.join = undefined;
        mt_menu_notice("Multiplayer", "No answer from " + _j.addr + ". Is the host in the game and the address right?");
        return;
    }
    mt_farm_arm_poll();
}

function mt_farm_on_info(_j, _info) {
    var _ident = real(string_digits(string(_info.farm_id)));
    var _path = mt_farm_find_save(_ident);
    var _tag = mt_farm_read_tag(_ident);
    var _is_ours = is_struct(_tag) && _tag[$ "role"] == "farmhand" && string(_tag[$ "farm_id"]) == string(_info.farm_id);
    if (_path != undefined && !_is_ours) {
        mt_menu_notice("Multiplayer", "You already have a save of your own with this farm's id, so it cannot be used for joining. Your save was not touched.");
        return;
    }
    if (_path != undefined) {
        if (_j.auto) { mt_farm_enter_continue(_j.addr, _info, _path); return; }
        var _popup = popup_creator(mt_menu_text(string(_info.farm_name)), mt_menu_text(string(_info.host_name) + "'s farm. Continue as your farmhand?"));
        _popup.create_button(mt_menu_text("Cancel"));
        _popup.create_button(mt_menu_text("Continue"), mt_farm_enter_continue, [_j.addr, _info, _path]);
        _popup.spawn();
        return;
    }
    if (_j.auto) { mt_farm_enter_create(_j.addr, _info, _j.name != "" ? _j.name : "Farmhand"); return; }
    mt_farm_ask_name(_j.addr, _info);
}

function mt_farm_ask_name(_addr, _info) {
    var _f = mt_farm_state();
    _f.ask = { addr: _addr, info: _info };
    text_input_popup(mt_menu_text("Name your farmhand"), "", 16, mt_farm_name_entered);
}

function mt_farm_name_entered(_name) {
    var _f = mt_farm_state();
    _name = string_trim(string(_name));
    if (_name == "" || _f[$ "ask"] == undefined) { return; }
    var _ask = _f.ask;
    _f.ask = undefined;
    mt_farm_enter_create(_ask.addr, _ask.info, _name);
}

function mt_farm_close_title() {
    try {
        var _menu = ANCHOR.get_menu(Menu.Title);
        if (_menu != undefined) { _menu.close(); }
    } catch (_e) {}
}

function mt_farm_enter_create(_addr, _info, _name) {
    var _f = mt_farm_state();
    mt_farm_close_title();
    global.__story_enabled = false;     // world progress follows the host
    var _preset = create_default_player_animation_assets();
    // Give each farmhand their own colours, derived from the name.
    var _n = 0;
    for (var _c = 1; _c <= string_length(_name); _c++) { _n += ord(string_char_at(_name, _c)); }
    for (var _i = 1; _i < _preset.assets.count(); _i++) {
        var _asset = _preset.assets.get(_i);
        _asset.lut_index = 1 + ((_asset.lut_index + _n * 7) % 12);
    }
    _preset.skin_tone = _n % 6;
    var _state = LoadState.New({
        name: _name,
        farm_name: string(_info.farm_name),
        pronouns: default_pronouns(),
        presets: List(_preset),
        preset_index_selected: 0,
        birthday: DEFAULT_ARI_BIRTHDAY,
    });
    _state.game_ident = real(string_digits(string(_info.farm_id)));
    _f.pending = { v: 1, role: "farmhand", farm_id: string(_info.farm_id), farm_name: string(_info.farm_name), host_name: string(_info.host_name) };
    _f.joining = string(_info.farm_id);
    mt_menu_set("join", _addr);
    mt_log("creating farmhand " + _name + " for farm " + _f.joining);
    Setup.enter_game(_state);
}

function mt_farm_enter_continue(_addr, _info, _path) {
    var _f = mt_farm_state();
    mt_farm_close_title();
    var _bundle = Setup.save_manager.manifest.get(_path);
    var _state = LoadState.Load(_bundle);
    patch_save(_state.loader);
    _f.joining = string(_info.farm_id);
    mt_menu_set("join", _addr);
    mt_log("continuing farmhand save for farm " + _f.joining);
    Setup.enter_game(_state);
}

// --- refusals ----------------------------------------------------------------------

// First frame in a world: a farmhand save can only be played through Join.
function mt_farm_on_world_entered() {
    var _f = mt_farm_state();
    if (mt_farm_is_farmhand() && _f.joining != mt_farm_tag_id()) {
        _f.notice = "This save belongs to another player's farm. Join that farm from the Multiplayer menu to play it.";
        mt_log("farmhand save loaded outside a join: back to the title");
        try { Game.exit_to_menu(); } catch (_e) { mmapi_warn_rate_limited("mt_farm_exit", MT_MOD, "could not leave: " + string(_e)); }
    }
}

// Back at the title: forget the loaded save's tag, show any pending notice.
function mt_farm_on_title() {
    var _f = mt_farm_state();
    _f.tag = undefined;
    _f.pending = undefined;
    _f.joining = "";
    mt_log("title entered, notice pending: " + string(_f.notice != ""));
    if (_f.notice != "") {
        new_chain()
            .join(LinkId.Timer, 90)
            .append(LinkId.Function, mt_farm_show_notice);
    }
}

function mt_farm_show_notice() {
    var _f = mt_farm_state();
    mt_log("showing notice: " + string(_f.notice));
    if (_f.notice == "") { return; }
    mt_menu_notice("Multiplayer", _f.notice);
    _f.notice = "";
    _f.notices_shown += 1;
}

// The host's hello names its farm; it must be the farm this save belongs to.
function mt_farm_check_host(_fid) {
    var _f = mt_farm_state();
    if (!mt_farm_is_farmhand() || !is_string(_fid)) { return; }
    if (_fid == mt_farm_tag_id()) { return; }
    mt_log("this farmhand belongs to another farm; disconnecting");
    _f.notice = "You joined a different farm than this character belongs to. Disconnected.";
    mt_menu_set("off");
    mt_ui_toast(_f.notice);
}

// The save guard: a farmhand's save is only written once the host's world has
// been adopted (before that the game holds an empty world).
function mt_farm_save_guard() {
    if (!mt_farm_is_farmhand()) { return undefined; }
    return mt_sync_state().adopted ? undefined : false;
}

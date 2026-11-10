// Mistria Together - MtMenu.gml: the Multiplayer menu.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hosting and joining are done from inside the game, with the game's own
// popups: a Multiplayer button on the title screen, and F9 while playing.
// The choice is written to <ipc dir>/control.json, which the background
// companion obeys; what the companion knows (its state, and the games it has
// found on the local network) comes back in link.json.

#macro MT_DEFAULT_PORT 7777

function mt_menu_text(_text) {
    return ANCHOR.wrap_for_local(string(_text));
}

// A fresh look at the companion's status file. undefined = not running.
function mt_menu_link() {
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { return undefined; }
    var _path = _rt.dir + "/link.json";
    try {
        if (!file_exists(_path)) { return undefined; }
        var _link = try_read_json_file(_path, undefined, false);
        if (is_struct(_link) && is_string(_link[$ "epoch"])) { return _link; }
    } catch (_e) {}
    return undefined;
}

// Tell the companion what to do: "off", "host" or "join".
function mt_menu_set(_mode, _addr = "") {
    var _rt = __mt_rt();
    var _cfg = mt_config();
    _rt.control_seq += 1;
    mt_ipc_write("control.json", json_stringify({
        seq: _rt.control_seq,
        nonce: irandom(999999999),
        mode: _mode,
        addr: _addr,
        port: MT_DEFAULT_PORT,
        password: _cfg.password,
    }));
    _rt.menu_mode = _mode;
    if (_mode == "join" && _addr != "" && _addr != _cfg.last_address) {
        _cfg.last_address = _addr;
        mmapi_config_write(MT_MOD, MT_CONFIG_VERSION, _cfg);
    }
    mt_log("multiplayer menu: " + _mode + (_addr != "" ? " " + _addr : ""));
}

function mt_menu_notice(_title, _text) {
    var _popup = popup_creator(mt_menu_text(_title), mt_menu_text(_text));
    _popup.create_button(mt_menu_text("OK"));
    _popup.spawn();
}

function mt_menu_open() {
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { mt_ipc_init(); }
    var _link = mt_menu_link();
    if (_link == undefined) {
        mt_menu_notice("Multiplayer", "The Mistria Together helper is not running. Run its installer once (it then starts by itself), and try again.");
        return;
    }
    var _mode = is_string(_link[$ "mode"]) ? _link.mode : "off";
    if (_mode == "off" && _rt.menu_mode != "off") {
        // We asked a moment ago and the helper has not caught up yet.
        _mode = _rt.menu_mode;
    }
    if (_mode == "off") {
        var _popup = popup_creator(mt_menu_text("Multiplayer"), mt_menu_text("Play together on one farm. One player hosts, the others join."));
        // Escape only closes: neither choice sits on the cancel key.
        _popup.create_button(mt_menu_text("Join"), mt_menu_on_join, [0], undefined, InputId.SecondaryInteract);
        _popup.create_button(mt_menu_text("Host"), mt_menu_on_host);
        _popup.spawn();
        return;
    }
    var _text = "";
    if (_rt.online) {
        var _count = array_length(_rt.peer_ids) + 1;
        _text = mt_is_host()
            ? "You are hosting. " + string(_count) + (_count == 1 ? " player" : " players") + " online."
            : "You are playing on " + mt_peer_name(_rt.host_id) + "'s farm.";
    } else if (_mode == "host") {
        _text = mt_in_world() ? "Starting to host..." : "Hosting starts as soon as you load a save.";
    } else {
        var _detail = is_string(_link[$ "detail"]) ? _link.detail : "";
        _text = mt_in_world()
            ? "Joining " + string(_link[$ "addr"]) + "..." + (_link[$ "state"] == "error" ? " (" + _detail + ")" : "")
            : "You join " + string(_link[$ "addr"]) + " as soon as you load a save.";
    }
    var _status = popup_creator(mt_menu_text("Multiplayer"), mt_menu_text(_text));
    _status.create_button(mt_menu_text("Close"));
    _status.create_button(mt_menu_text("Disconnect"), mt_menu_on_disconnect);
    _status.spawn();
}

function mt_menu_on_host() {
    mt_menu_set("host");
    if (!mt_in_world()) {
        mt_menu_notice("Multiplayer", "Hosting starts as soon as you load a save. Others on your network will find you by themselves; over the internet they need your address.");
    }
}

function mt_menu_on_disconnect() {
    mt_menu_set("off");
}

// Offer the games found on the local network one after another, then the
// address box.
function mt_menu_on_join(_index) {
    var _link = mt_menu_link();
    var _lan = (_link != undefined && is_array(_link[$ "lan"])) ? _link.lan : [];
    if (_index < array_length(_lan)) {
        var _game = _lan[_index];
        var _players = _game[$ "players"];
        var _text = "Found " + string(_game[$ "name"]) + "'s game on your network"
            + (is_numeric(_players) ? " (" + string(_players) + (_players == 1 ? " player)." : " players).") : ".");
        var _popup = popup_creator(mt_menu_text("Join a game"), mt_menu_text(_text));
        _popup.create_button(mt_menu_text(_index + 1 < array_length(_lan) ? "Next" : "Other"), mt_menu_on_join, [_index + 1], undefined, InputId.SecondaryInteract);
        _popup.create_button(mt_menu_text("Join"), mt_menu_join_address, [string(_game[$ "addr"])]);
        _popup.spawn();
        return;
    }
    text_input_popup(mt_menu_text("Host's address"), mt_config().last_address, 150, mt_menu_join_address);
}

function mt_menu_join_address(_addr) {
    _addr = string_trim(string(_addr));
    if (_addr == "") { return; }
    mt_menu_set("join", _addr);
    if (!mt_in_world()) {
        mt_menu_notice("Multiplayer", "You join " + _addr + " as soon as you load a save.");
    }
}

// --- title screen ----------------------------------------------------------

function mt_menu_on_title(_ctx) {
    var _rt = __mt_rt();
    _rt.title_boot = _ctx[$ "from_game"] != true;
    new_chain()
        .join(LinkId.Timer, 20)
        .append(LinkId.Function, mt_menu_title_setup);
}

function mt_menu_title_setup() {
    var _rt = __mt_rt();
    try {
        if (_rt.dir == undefined) { mt_ipc_init(); }
        mt_config();
        // A fresh start of the game never resumes an old session by itself.
        if (_rt.title_boot) { mt_menu_set("off"); }
        mt_ipc_write_game(true);
    } catch (_e) {
        mt_warn("title setup failed: " + string(_e));
    }
    try {
        mt_menu_free_title_button();
        var _button = ANCHOR.nine_slice(ANCHOR.screen_canvas)
            .set_size(90, 24)
            .set_align(Align.RightIn, Align.TopIn)
            .set_xy(-6, 6)
            .set_sprites_from_key("spr_ui_main_menu_button")
            .set_tap_callback(mt_menu_open)
            .add_text_label(mt_menu_text("Multiplayer"), COMMON_LUT, CommonLutIndex.BlackOnBeige)
            .add_hover_outline(spr_ui_main_menu_button_hover_outline);
        _button.text_label.add_y(-1);
        _button.hover_outline.set_size(_button.width + 4, _button.height + 4);
        _rt.title_button = _button;
    } catch (_e2) {
        mt_warn("could not add the Multiplayer button to the title screen: " + string(_e2));
    }
}

function mt_menu_free_title_button() {
    var _rt = __mt_rt();
    if (_rt.title_button == undefined) { return; }
    try { ANCHOR.free_node(_rt.title_button); } catch (_e) {}
    _rt.title_button = undefined;
}

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

function mt_menu_save_config() {
    mmapi_config_write(MT_MOD, MT_CONFIG_VERSION, mt_config());
}

function mt_menu_friends() {
    var _cfg = mt_config();
    var _friends = _cfg.friends;
    var _popup = popup_creator(mt_menu_text("Friends"), mt_menu_text(array_length(_friends) == 0
        ? "Save a friend's name and network address for quick joining. Names are labels you choose."
        : "Browse saved friends by name. Network addresses stay hidden."));
    if (array_length(_friends) > 0) {
        _popup.create_button(mt_menu_text("Browse Friends"), mt_menu_friend_browse, [0]);
        _popup.create_button(mt_menu_text("Add Friend"), mt_menu_add_friend);
    } else {
        _popup.create_button(mt_menu_text("Add Friend"), mt_menu_add_friend);
        _popup.create_button(mt_menu_text("Close"));
    }
    _popup.spawn();
}

function mt_menu_friend_browse(_index) {
    var _friends = mt_config().friends;
    if (array_length(_friends) == 0) { mt_menu_friends(); return; }
    _index = _index mod array_length(_friends);
    var _f = _friends[_index];
    var _popup = popup_creator(mt_menu_text("Saved Friends"), mt_menu_text(_f.name + "\nChoose this friend to join or remove them."));
    _popup.create_button(mt_menu_text("Next"), mt_menu_friend_browse, [_index + 1]);
    _popup.create_button(mt_menu_text("Choose"), mt_menu_friend_selected, [_index]);
    _popup.spawn();
}

function mt_menu_add_friend(_unused = 0) {
    text_input_popup(mt_menu_text("Friend's name"), "", 32, mt_menu_friend_name_entered);
}

function mt_menu_friend_name_entered(_name) {
    _name = string_trim(string(_name));
    if (_name == "" || string_length(_name) > 32) {
        mt_menu_notice("Friends", "Enter a name up to 32 characters long.");
        return;
    }
    __mt_rt().pending_friend_name = _name;
    text_input_popup(mt_menu_text("Host name or address"), "", 253, mt_menu_friend_address_entered);
}

function mt_menu_friend_address_entered(_address, _name) {
    _name = __mt_rt().pending_friend_name;
    __mt_rt().pending_friend_name = undefined;
    _name = string_trim(string(_name));
    _address = string_trim(string(_address));
    var _friends = mt_config().friends;
    if (_address == "" || string_length(_address) > 253) {
        mt_menu_notice("Friends", "Enter a hostname or IP address up to 253 characters long.");
        return;
    }
    for (var _i = 0; _i < array_length(_friends); _i++) {
        var _f = _friends[_i];
        if (is_struct(_f) && string_lower(_f.name) == string_lower(_name)) {
            mt_menu_notice("Friends", "A friend with that name is already saved.");
            return;
        }
    }
    array_push(_friends, { name: _name, address: _address });
    mt_menu_save_config();
    mt_menu_friends();
}

function mt_menu_friend_selected(_index) {
    var _friends = mt_config().friends;
    if (_index < 0 || _index >= array_length(_friends)) { return; }
    var _f = _friends[_index];
    var _popup = popup_creator(mt_menu_text(_f.name), mt_menu_text("Connect to this saved friend?"));
    _popup.create_button(mt_menu_text("Join"), mt_menu_friend_join, [_index]);
    _popup.create_button(mt_menu_text("Remove"), mt_menu_friend_remove, [_index]);
    _popup.spawn();
}

function mt_menu_friend_join(_index) {
    var _friends = mt_config().friends;
    if (_index < 0 || _index >= array_length(_friends)) { return; }
    var _f = _friends[_index];
    mt_menu_set("join", _f.address);
    if (!mt_in_world()) { mt_menu_notice("Multiplayer", "Joining " + _f.name + " starts when you load a save."); }
}

function mt_menu_friend_remove(_index) {
    var _friends = mt_config().friends;
    if (_index < 0 || _index >= array_length(_friends)) { return; }
    array_delete(_friends, _index, 1);
    mt_menu_save_config();
    mt_menu_friends();
}

function mt_menu_settings(_page = 0) {
    var _cfg = mt_config();
    var _desc = _page == 0
        ? "Local display choices affect only you. The host owns the shared farm, time, weather, upgrades and decor. Inventory, money, skills, relationships and story remain personal."
        : "Password changes apply to your next session. The host owns shared-farm settings.";
    var _popup = popup_creator(mt_menu_text("Multiplayer Settings"), mt_menu_text(_desc));
    if (_page == 0) {
        _popup.create_button(mt_menu_text("HUD: " + (_cfg.show_hud ? "On" : "Off")), mt_menu_toggle_hud);
        _popup.create_button(mt_menu_text("Next"), mt_menu_settings, [1]);
    } else if (_page == 1) {
        _popup.create_button(mt_menu_text("Name tags: " + (_cfg.name_tags ? "On" : "Off")), mt_menu_toggle_names);
        _popup.create_button(mt_menu_text("Next"), mt_menu_settings, [2]);
    } else {
        _popup.create_button(mt_menu_text("Smoothing: " + string(_cfg.smoothing_frames)), mt_menu_smoothing);
        _popup.create_button(mt_menu_text("Password: " + (_cfg.password == "" ? "None" : "Set")), mt_menu_change_password);
    }
    _popup.spawn();
}

function mt_menu_toggle_hud(_unused = 0) {
    var _cfg = mt_config(); _cfg.show_hud = !_cfg.show_hud;
    __mt_rt().hud_visible = _cfg.show_hud;
    mt_menu_save_config(); mt_menu_settings();
}

function mt_menu_toggle_names(_unused = 0) {
    var _cfg = mt_config(); _cfg.name_tags = !_cfg.name_tags;
    mt_menu_save_config(); mt_menu_settings();
}

function mt_menu_smoothing(_unused = 0) {
    var _cfg = mt_config();
    _cfg.smoothing_frames = _cfg.smoothing_frames >= 26 ? 2 : _cfg.smoothing_frames + 6;
    mt_menu_save_config(); mt_menu_settings();
}

function mt_menu_change_password(_unused = 0) {
    text_input_popup(mt_menu_text("Session password (blank for none)"), mt_config().password, 64, mt_menu_password_entered);
}

function mt_menu_password_entered(_password) {
    mt_config().password = string(_password);
    mt_menu_save_config(); mt_menu_settings();
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
        var _popup = popup_creator(mt_menu_text("Multiplayer"), mt_menu_text("Play together on one farm. Choose a nearby game or open more options."));
        // Escape only closes: neither choice sits on the cancel key.
        _popup.create_button(mt_menu_text("Nearby"), mt_menu_on_join, [0], undefined, InputId.SecondaryInteract);
        _popup.create_button(mt_menu_text("More"), mt_menu_more);
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

function mt_menu_more(_unused = 0) {
    var _popup = popup_creator(mt_menu_text("Multiplayer"), mt_menu_text("Host a farm, or manage saved friends and settings."));
    _popup.create_button(mt_menu_text("Host"), mt_menu_on_host);
    _popup.create_button(mt_menu_text("Friends & Settings"), mt_menu_connections);
    _popup.spawn();
}

function mt_menu_connections(_unused = 0) {
    var _popup = popup_creator(mt_menu_text("Connections"), mt_menu_text("Saved host names and local multiplayer options."));
    _popup.create_button(mt_menu_text("Friends"), mt_menu_friends);
    _popup.create_button(mt_menu_text("Settings"), mt_menu_settings);
    _popup.spawn();
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

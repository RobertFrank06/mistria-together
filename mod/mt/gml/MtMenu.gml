// Mistria Together - MtMenu.gml: the Multiplayer menu.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hosting and joining use the game's native menu choices: Multiplayer from the
// title screen, and F9 while playing.
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

function mt_menu_friends(_page = 0) {
    var _cfg = mt_config();
    var _friends = _cfg.friends;
    var _count = array_length(_friends);
    if (_count == 0) {
        var _empty = popup_creator(mt_menu_text("Saved Friends"), mt_menu_text("No saved friends yet. Add a friend's name and hostname or address to join them later."));
        _empty.create_button(mt_menu_text("Back"), mt_menu_join_menu);
        _empty.create_button(mt_menu_text("Add Friend"), mt_menu_add_friend);
        _empty.spawn();
        return;
    }

    var _per_page = 5;
    var _pages = ceil(_count / _per_page);
    _page = clamp(_page, 0, _pages - 1);
    var _start = _page * _per_page;
    var _end = min(_start + _per_page, _count);
    var _menu = new MultipleChoicePopup(mt_menu_text("Saved Friends"));
    for (var _i = _start; _i < _end; _i++) {
        var _f = _friends[_i];
        var _label = string(_f.name);
        if (string_length(_label) > 16) { _label = string_copy(_label, 1, 13) + "..."; }
        _menu.option(mt_menu_text(_label), mt_menu_friend_selected, [_i]);
    }
    if (_page > 0) { _menu.option(mt_menu_text("Previous"), mt_menu_friends, [_page - 1]); }
    if (_end < _count) { _menu.option(mt_menu_text("Next"), mt_menu_friends, [_page + 1]); }
    _menu.option(mt_menu_text("Back"), mt_menu_join_menu);
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
    var _menu = new MultipleChoicePopup(mt_menu_text(_f.name));
    _menu.option(mt_menu_text("Join"), mt_menu_friend_join, [_index]);
    _menu.option(mt_menu_text("Remove"), mt_menu_friend_remove, [_index]);
    _menu.option(mt_menu_text("Back"), mt_menu_friends, [floor(_index / 5)]);
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

function mt_menu_settings(_unused = 0) {
    var _cfg = mt_config();
    var _menu = new MultipleChoicePopup(mt_menu_text("Multiplayer Settings"));
    _menu.option(mt_menu_text("HUD " + (_cfg.show_hud ? "On" : "Off")), mt_menu_toggle_hud);
    _menu.option(mt_menu_text("Names " + (_cfg.name_tags ? "On" : "Off")), mt_menu_toggle_names);
    _menu.option(mt_menu_text("Smooth " + string(_cfg.smoothing_frames)), mt_menu_smoothing);
    _menu.option(mt_menu_text("Password " + (_cfg.password == "" ? "None" : "Set")), mt_menu_change_password);
    _menu.option(mt_menu_text("Back"), mt_menu_main);
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
        mt_menu_main();
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
    _status.create_button(mt_menu_text("Settings"), mt_menu_settings);
    _status.create_button(mt_menu_text("Disconnect"), mt_menu_on_disconnect);
    _status.spawn();
}

function mt_menu_main(_unused = 0) {
    var _menu = new MultipleChoicePopup(mt_menu_text("Multiplayer"));
    _menu.option(mt_menu_text("Join"), mt_menu_join_menu);
    _menu.option(mt_menu_text("Host"), mt_menu_on_host);
    _menu.option(mt_menu_text("Settings"), mt_menu_settings);
}

function mt_menu_join_menu(_unused = 0) {
    var _menu = new MultipleChoicePopup(mt_menu_text("Join Multiplayer"));
    _menu.option(mt_menu_text("Nearby Games"), mt_menu_nearby);
    _menu.option(mt_menu_text("Saved Friends"), mt_menu_friends);
    _menu.option(mt_menu_text("Add Friend"), mt_menu_add_friend);
    _menu.option(mt_menu_text("Direct Join"), mt_menu_direct_join);
    _menu.option(mt_menu_text("Back"), mt_menu_main);
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

function mt_menu_direct_join(_unused = 0) {
    text_input_popup(mt_menu_text("Host's address"), mt_config().last_address, 253, mt_menu_join_address);
}

// Show a bounded page of discoveries so large networks cannot push the menu
// outside the screen. Companion discovery refreshes independently.
function mt_menu_nearby(_page = 0) {
    var _link = mt_menu_link();
    var _lan = (_link != undefined && is_array(_link[$ "lan"])) ? _link.lan : [];
    var _count = array_length(_lan);
    if (_count == 0) {
        var _empty = popup_creator(mt_menu_text("Nearby Games"), mt_menu_text("No nearby games found. Try again or choose a saved friend or direct address."));
        _empty.create_button(mt_menu_text("Back"), mt_menu_join_menu);
        _empty.create_button(mt_menu_text("Refresh"), mt_menu_nearby, [0]);
        _empty.spawn();
        return;
    }

    var _per_page = 5;
    var _pages = ceil(_count / _per_page);
    _page = clamp(_page, 0, _pages - 1);
    var _start = _page * _per_page;
    var _end = min(_start + _per_page, _count);
    var _menu = new MultipleChoicePopup(mt_menu_text("Nearby Games"));
    for (var _i = _start; _i < _end; _i++) {
        var _game = _lan[_i];
        var _players = _game[$ "players"];
        var _label = string(_game[$ "name"]);
        if (is_numeric(_players)) { _label += " (" + string(_players) + ")"; }
        if (string_length(_label) > 16) { _label = string_copy(_label, 1, 13) + "..."; }
        _menu.option(mt_menu_text(_label), mt_menu_join_address, [string(_game[$ "addr"])]);
    }
    if (_page > 0) { _menu.option(mt_menu_text("Previous"), mt_menu_nearby, [_page - 1]); }
    if (_end < _count) { _menu.option(mt_menu_text("Next"), mt_menu_nearby, [_page + 1]); }
    _menu.option(mt_menu_text("Back"), mt_menu_join_menu);
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
    mt_menu_free_title_button();
    new_chain()
        .append(LinkId.Await, function() {
            var _title = ANCHOR.get_menu(Menu.Title);
            return _title != undefined && _title[$ "button_root"] != undefined;
        })
        .append(LinkId.Function, mt_menu_title_add_button);
}

function mt_menu_title_add_button() {
    var _rt = __mt_rt();
    try {
        var _title = ANCHOR.get_menu(Menu.Title);
        if (_title == undefined || _title[$ "button_root"] == undefined || _title.pilot == undefined) { return; }
        if (_title[$ "mt_multiplayer_button"] != undefined && !_title[$ "mt_multiplayer_button"].freed) { return; }

        var _saves = Setup.save_manager.get_saves_ordered();
        var _has_continue = !array_is_empty(_saves);
        var _insert_row = _has_continue ? 2 : 1;
        var _rows = _title.pilot.map;
        if (_insert_row >= array_length(_rows) || array_length(_rows[_insert_row - 1]) == 0) {
            throw "title button list is not in the expected order";
        }

        var _previous = _rows[_insert_row - 1][0];
        var _button_y = _previous.get_y() + _previous.get_height() + 6;
        var _button = ANCHOR.nine_slice(_title.button_root)
            .set_size(90, 24)
            .set_align(Align.Center, Align.TopIn)
            .set_y(_button_y)
            .set_alpha(1)
            .add_to_pilot(_title.pilot, true)
            .set_sprites_from_key("spr_ui_main_menu_button")
            .set_locked_sprite(spr_ui_main_menu_button_main)
            .set_tap_callback(mt_menu_open)
            .add_text_label(mt_menu_text("Multiplayer"), COMMON_LUT, CommonLutIndex.BlackOnBeige)
            .add_hover_outline(spr_ui_main_menu_button_hover_outline)
            .lock();
        _button.text_label.add_y(-1);
        _button.hover_outline.set_size(_button.width + 4, _button.height + 4);
        _button.update_width = function(_self) {
            static WIDTH_DATA = fiddle_get("ui/misc/local_adjustments/title_menu_button");
            _self.set_width(WIDTH_DATA[$ local_language()] ?? WIDTH_DATA[$ "default"]);
            _self.hover_outline.set_size(_self.width + 4, _self.height + 4);
        };
        _button.set_think_callback(_button.update_width, [_button], true);
        _button.unlock();

        // The native title menu adds each button as a one-node pilot row.
        // Insert after New Game and shift the later rows down one slot.
        var _row_count = array_length(_title.pilot.map);
        for (var _row_index = _row_count - 2; _row_index >= _insert_row; _row_index--) {
            var _row = _title.pilot.map[_row_index];
            for (var _col = 0; _col < array_length(_row); _col++) {
                var _node = _row[_col];
                if (_node != undefined) { _node.add_y(_button.height + 6); }
            }
            _title.pilot.map[_row_index + 1] = _row;
        }
        _title.pilot.map[_insert_row] = [_button];
        _title.button_position += _button.height + 6;
        _title.total_height += _button.height + 6;
        _title.button_root.set_height(_title.total_height);

        _title.mt_multiplayer_button = _button;
        _rt.title_button = _button;
        mt_log("Multiplayer button inserted after New Game on the title screen");

        // Developer-only menu smoke modes keep the title screen open and show
        // one page so the isolated rig can compile and instantiate each UI.
        var _dev_mode = mt_dev_state().mode;
        switch (_dev_mode) {
            case "menu-main": mt_menu_main(); break;
            case "menu-join": mt_menu_join_menu(); break;
            case "menu-nearby": mt_menu_nearby(); break;
            case "menu-friends": mt_menu_friends(); break;
            case "menu-settings": mt_menu_settings(); break;
        }
    } catch (_e2) {
        mt_warn("could not add Multiplayer to the title screen: " + string(_e2));
    }
}

function mt_menu_free_title_button() {
    var _rt = __mt_rt();
    if (_rt.title_button == undefined) { return; }
    try { ANCHOR.free_node(_rt.title_button); } catch (_e) {}
    _rt.title_button = undefined;
}

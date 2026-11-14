// Mistria Together - MtNight.gml: the group day end.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Going to bed means "I am ready", not "start the night". The host keeps the
// ready set; the night starts only when every online player is ready.
//   * Bed (cancellable): the bed interaction is taken over (object.interact).
//     The player waits in a popup; the game's real sleep scene runs only when
//     the host announces the night.
//   * Held (not cancellable): the game's own day-ending path already started
//     (passing out, dying, a day-ending scene), so the player sits at the
//     overnight summary with its "next day" button locked until the night
//     starts.
// Messages: nr {r, held} any -> host; ns {ready, total} host -> all;
// ng {day} host -> all.

function mt_night_state() {
    var _rt = __mt_rt();
    if (_rt[$ "night"] == undefined) { mt_night_reset(); }
    return _rt.night;
}

function mt_night_reset() {
    var _rt = __mt_rt();
    var _old = _rt[$ "night"];
    if (_old != undefined) { mt_night_close_popup(_old); mt_night_unlock(_old); }
    _rt.night = {
        bed: false,         // waiting in bed
        held: false,        // waiting at the overnight summary
        gate_open: false,   // the host announced this night
        popup: undefined,
        popup_text: "",
        no_popup_frames: 0,
        locked: false,      // we locked the summary's button
        morning: undefined, // guest: waiting for the host's morning { applied, frames, popup }
        ready: {},          // host: id -> { held }
        ready_ids: [],      // everyone: last ns
        total: 0,
        day: -1,
    };
}

// --- pure logic (unit-testable) ---------------------------------------------

// True when every online player is in the ready list.
function mt_night_all_ready(_online_ids, _ready_ids) {
    if (array_length(_online_ids) == 0) { return false; }
    for (var _i = 0; _i < array_length(_online_ids); _i++) {
        var _found = false;
        for (var _j = 0; _j < array_length(_ready_ids); _j++) {
            if (_ready_ids[_j] == _online_ids[_i]) { _found = true; break; }
        }
        if (!_found) { return false; }
    }
    return true;
}

function mt_night_active() {
    var _rt = __mt_rt();
    return _rt.online && array_length(_rt.peer_ids) > 0 && mt_config().sync_world;
}

// --- bed takeover ------------------------------------------------------------

// object.interact override: claim only beds, only while playing together.
function mt_night_on_interact(_node) {
    if (!mt_night_active()) { return undefined; }
    var _lock = mt_items_on_interact(_node);
    if (_lock != undefined) { return _lock; }
    try {
        if (_node.prototype.bed_kind == undefined) { return undefined; }
        if (!is_home_location(CURRENT_LOCATION_ID) || !requirements_pass(Requirement.Sleep)) { return undefined; }
        var _n = mt_night_state();
        if (_n.bed || _n.held) { return true; }
        var _popup = popup_creator("misc_local/bed", "misc_local/go_to_sleep");
        _popup.create_button("misc_local/cancel");
        _popup.create_button("misc_local/sleep", mt_night_go_bed, [_node]);
        _popup.spawn();
        return true;
    } catch (_e) {
        mmapi_warn_rate_limited("mt_night_interact", MT_MOD, "bed takeover failed: " + string(_e));
        return undefined;
    }
}

// The player said "sleep": record the bed as the game does, then wait.
function mt_night_go_bed(_node) {
    var _n = mt_night_state();
    if (TAXI.is_traveling() || _n.bed || _n.held) { return; }
    if (CLOCK.time >= hours(25) + minutes(50)) { T2R.write("slept_last_minute", true); }
    if (_node != undefined) {
        ARI.last_bed_used = {
            location_id: CURRENT_LOCATION_ID,
            ni: GRID.node_index_for_cell(_node.top_left_x, _node.top_left_y),
        };
    }
    var _spouse = undefined;
    with (par_NPC) {
        if (!self.me.is_spouse()) { continue; }
        _spouse = npc_id_to_string(self.npc_id);
        break;
    }
    MIST.blackboard.insert("spouse", _spouse);
    MIST.blackboard.insert("spouse_is_present", _spouse != undefined);
    if (!mt_night_active()) {
        // Alone: the game's own bed, exactly as without the mod.
        MIST.request_scene("sleep");
        return;
    }
    _n.bed = true;
    mt_night_report(1, 0);
    mt_night_show_popup();
}

function mt_night_get_up(_unused = 0) {
    var _n = mt_night_state();
    if (!_n.bed) { return; }
    _n.bed = false;
    mt_night_close_popup(_n);
    mt_night_report(0, 0);
}

function mt_night_status_text() {
    var _n = mt_night_state();
    var _rt = __mt_rt();
    var _total = array_length(_rt.peer_ids) + 1;
    var _text = "Waiting for everyone to go to bed. " + string(array_length(_n.ready_ids)) + " of " + string(_total) + " ready.";
    for (var _i = 0; _i < array_length(_rt.peer_ids); _i++) {
        var _id = _rt.peer_ids[_i];
        var _on = false;
        for (var _j = 0; _j < array_length(_n.ready_ids); _j++) { if (_n.ready_ids[_j] == _id) { _on = true; } }
        _text += "\n" + (_on ? "[x] " : "[ ] ") + mt_peer_name(_id);
    }
    return _text;
}

function mt_night_show_popup() {
    var _n = mt_night_state();
    mt_night_close_popup(_n);
    _n.popup_text = mt_night_status_text();
    var _popup = popup_creator(mt_menu_text("In bed"), mt_menu_text(_n.popup_text));
    _popup.create_button(mt_menu_text("Get up"), mt_night_get_up);
    _popup.spawn();
    _n.popup = _popup;
    _n.no_popup_frames = 0;
}

function mt_night_close_popup(_n) {
    if (_n.popup == undefined) { return; }
    try { _n.popup.close(); } catch (_e) {}
    _n.popup = undefined;
}

// --- reporting ----------------------------------------------------------------

function mt_night_report(_ready, _held) {
    var _rt = __mt_rt();
    if (mt_is_host()) {
        mt_night_host_set(_rt.self_id, _ready == 1, _held);
    } else {
        mt_send(MT_TO_HOST, { t: "nr", r: _ready, held: _held });
    }
}

// --- host: the ready set --------------------------------------------------------

function mt_night_host_set(_id, _on, _held) {
    var _n = mt_night_state();
    var _key = string(_id);
    if (_on) { _n.ready[$ _key] = { held: _held == 1 }; }
    else if (_n.ready[$ _key] != undefined) { struct_remove(_n.ready, _key); }
    mt_night_host_check();
}

function mt_night_host_check() {
    var _rt = __mt_rt();
    var _n = mt_night_state();
    if (!mt_is_host()) { return; }
    var _online = [_rt.self_id];
    for (var _i = 0; _i < array_length(_rt.peer_ids); _i++) { array_push(_online, _rt.peer_ids[_i]); }
    var _ready = [];
    for (var _k = 0; _k < array_length(_online); _k++) {
        if (_n.ready[$ string(_online[_k])] != undefined) { array_push(_ready, _online[_k]); }
    }
    var _all = !_n.gate_open && array_length(_online) > 1 && mt_night_all_ready(_online, _ready);
    if (!_all) {
        _n.ready_ids = _ready;
        mt_send(MT_TO_ALL, { t: "ns", ready: _ready, total: array_length(_online) });
        if (_n.bed && _n.popup != undefined) { mt_night_show_popup(); }
        return;
    }
    // Everyone is ready: the night starts.
    var _w = mt_world_state();
    _w.st_night = true;
    _w.time_sent_frame = -100000;
    _n.day = CALENDAR.time;
    mt_log("night starts, " + string(array_length(_online)) + " player(s) ready");
    var _bin = mt_money_bin_total();
    var _shares = mt_money_state().mode == "shared" ? mt_money_split(_bin, [_rt.self_id], _rt.self_id) : mt_money_split(_bin, _online, _rt.self_id);
    mt_send(MT_TO_ALL, { t: "ng", day: _n.day, bin: _bin, shares: _shares });
    mt_money_on_night(_n.day, _bin, _shares);
    mt_night_run();
}

function mt_night_on_message(_peer, _t, _d) {
    var _rt = __mt_rt();
    var _n = mt_night_state();
    switch (_t) {
        case "nr":
            if (mt_is_host()) { mt_night_host_set(_peer.id, _d[$ "r"] == 1, _d[$ "held"]); }
            break;
        case "ns":
            if (_peer.id != _rt.host_id) { break; }
            _n.ready_ids = is_array(_d[$ "ready"]) ? _d.ready : [];
            if (_n.bed && _n.popup != undefined) { mt_night_show_popup(); }
            break;
        case "ng":
            if (_peer.id != _rt.host_id) { break; }
            _n.day = _d[$ "day"];
            mt_money_on_night(_n.day, _d[$ "bin"] ?? 0, _d[$ "shares"]);
            mt_world_state().st_night = true;
            mt_night_run();
            break;
    }
}

// The night is on: bed players run the game's sleep scene, held players are let go.
function mt_night_run() {
    var _n = mt_night_state();
    _n.gate_open = true;
    mt_night_close_popup(_n);
    mt_night_unlock(_n);
    if (_n.bed) {
        _n.bed = false;
        try { MIST.request_scene("sleep"); }
        catch (_e) { mmapi_warn_rate_limited("mt_night_scene", MT_MOD, "could not start the sleep scene: " + string(_e)); }
    }
}

// --- held at the summary ----------------------------------------------------------

function mt_night_unlock(_n) {
    if (!_n.locked) { return; }
    _n.locked = false;
    try {
        var _eod = ANCHOR.get_menu(Menu.Eod);
        if (_eod != undefined && _eod[$ "next_day_button"] != undefined) { _eod.next_day_button.unlock(); }
    } catch (_e) {}
}

// Per frame, while online with others.
function mt_night_tick() {
    var _n = mt_night_state();
    if (!mt_night_active()) {
        if (_n.locked) { mt_night_unlock(_n); }
        _n.held = false;
        if (_n.bed) { _n.bed = false; mt_night_close_popup(_n); }
        return;
    }
    // The waiting popup was dismissed some other way: that means "get up".
    if (_n.bed && _n.popup != undefined) {
        if (ANCHOR.get_menu(Menu.Popup) == undefined) {
            _n.no_popup_frames += 1;
            if (_n.no_popup_frames > 10) { _n.popup = undefined; mt_night_get_up(); }
        } else { _n.no_popup_frames = 0; }
    }
    mt_night_tick_morning();
    var _eod = ANCHOR.get_menu(Menu.Eod);
    if (_eod == undefined) { return; }
    if (_n.gate_open) { return; }
    // The day is ending for this player without the group: hold them here.
    if (!_n.held) {
        _n.held = true;
        if (_n.bed) { _n.bed = false; mt_night_close_popup(_n); }
        mt_night_report(1, 1);
    }
    var _btn = _eod[$ "next_day_button"];
    if (_btn != undefined && _btn.is_unlocked()) {
        _btn.lock();
        _n.locked = true;
    }
}

// --- events -------------------------------------------------------------------------

function mt_night_on_new_day(_ctx) {
    var _rt = __mt_rt();
    if (!_rt.online) { return; }
    var _n = mt_night_state();
    var _was_night = _n.gate_open;
    if (!_n.gate_open && array_length(_rt.peer_ids) > 0) {
        mt_warn("the day ended without the group's night; falling back to the host's world");
    }
    if (!mt_is_host() && _was_night && array_length(_rt.peer_ids) > 0) { mt_night_wait_morning(); }
    mt_night_close_popup(_n);
    _n.bed = false;
    _n.held = false;
    _n.gate_open = false;
    _n.locked = false;
    _n.ready = {};
    _n.ready_ids = [];
    if (mt_is_host()) { mt_send(MT_TO_ALL, { t: "ns", ready: [], total: array_length(_rt.peer_ids) + 1 }); }
}

// A guest's own night is over; its morning is the host's. Wait for it.
function mt_night_wait_morning() {
    var _n = mt_night_state();
    var _popup = undefined;
    try {
        _popup = popup_creator(mt_menu_text("Good morning"), mt_menu_text("Waiting for the host's morning..."));
        _popup.create_button(mt_menu_text("OK"));
        _popup.spawn();
    } catch (_e) { _popup = undefined; }
    _n.morning = { applied: mt_sync_state().applied, frames: 0, popup: _popup };
}

function mt_night_tick_morning() {
    var _n = mt_night_state();
    var _m = _n.morning;
    if (_m == undefined) { return; }
    _m.frames += 1;
    if (mt_sync_state().applied > _m.applied || _m.frames > 900) {
        try { if (_m.popup != undefined) { _m.popup.close(); } } catch (_e) {}
        _n.morning = undefined;
    }
}

// A player left: they no longer count, and the night may start without them.
function mt_night_on_leave(_id) {
    var _n = mt_night_state();
    if (mt_is_host()) {
        if (_n.ready[$ string(_id)] != undefined) { struct_remove(_n.ready, string(_id)); }
        mt_night_host_check();
    }
    if (array_length(__mt_rt().peer_ids) == 0) { mt_night_reset(); }
}

function mt_night_dev_state() {
    var _n = mt_night_state();
    var _eod = ANCHOR.get_menu(Menu.Eod);
    var _btn = _eod == undefined ? undefined : _eod[$ "next_day_button"];
    return {
        bed: _n.bed, held: _n.held, gate_open: _n.gate_open, ready: _n.ready_ids,
        eod: _eod != undefined,
        eod_button: _btn != undefined,
        eod_locked: _btn != undefined ? !_btn.is_unlocked() : false,
    };
}

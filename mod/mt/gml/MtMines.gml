// Mistria Together - MtMines.gml: shared mine floors (experimental).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Behind a host setting. While on, players on the same floor share the layout
// (every game seeds the floor's generation from a session seed + the floor
// number) and the breakable objects on it. Monsters and their drops stay
// local. The game's own random numbers are restored right after the floor is
// built so play is not predictable.

function mt_mines_floor() {
    try { return DUNGEON_RUNNER.current_floor; } catch (_e) { return -1; }
}

// The host's setting, as known on this machine.
function mt_mines_enabled() {
    var _rt = __mt_rt();
    if (!_rt.online || array_length(_rt.peer_ids) == 0) { return false; }
    return mt_world_state().mines;
}

// The game picks the dungeon's rooms (its itinerary) with random numbers that
// seeding does not control, so the host picks them once a day and sends the
// list. Rooms travel as text: their numeric ids are too big for JSON numbers.
function mt_mines_host_make() {
    if (!mt_is_host() || !mt_mines_enabled()) { return; }
    try {
        var _it = create_dungeon_itinerary(undefined);
        var _arr = [];
        for (var _i = 0; _i < _it.count(); _i++) {
            var _lv = _it.get(_i);
            array_push(_arr, { i: _lv.impl, r: string(_lv.gm_room), b: _lv.biome });
        }
        mt_world_state().mine_itin = _arr;
        mt_send(MT_TO_ALL, { t: "mi", l: _arr });
        mt_log("mines: made the day's itinerary (" + string(array_length(_arr)) + " floors)");
    } catch (_e) {
        mmapi_warn_rate_limited("mt_mines_make", MT_MOD, "could not make the mine itinerary: " + string(_e));
    }
}

function mt_mines_on_message(_peer, _t, _d) {
    if (_t == "mi" && _peer.id == __mt_rt().host_id && is_array(_d[$ "l"])) { mt_world_state().mine_itin = _d.l; }
}

function mt_mines_on_runner_created(_ctx) {
    var _w = mt_world_state();
    mt_log("mines: runner created, enabled=" + string(mt_mines_enabled()) + ", itinerary known=" + string(_w.mine_itin != undefined));
    if (!mt_mines_enabled() || _w.mine_itin == undefined) { return; }
    try {
        var _list = List();
        for (var _i = 0; _i < array_length(_w.mine_itin); _i++) {
            var _e = _w.mine_itin[_i];
            _list.push({ impl: _e.i, gm_room: int64(_e.r), biome: _e.b });
        }
        _ctx.runner.itinerary = _list;
        mt_log("mines: using the host's itinerary, first room " + string(_e.r));
    } catch (_e2) {
        mmapi_warn_rate_limited("mt_mines_itinerary", MT_MOD, "could not use the host's mine rooms: " + string(_e2));
    }
}

function mt_mines_on_build_begin(_ctx) {
    if (!mt_mines_enabled()) { return; }
    var _floor = is_struct(_ctx) && is_numeric(_ctx[$ "floor"]) ? _ctx.floor : mt_mines_floor();
    random_set_seed(mt_world_state().mine_seed + _floor * 7919);
    mt_mines_state().seeded = true;
}

function mt_mines_on_floor_built(_ctx) {
    var _m = mt_mines_state();
    if (!_m.seeded) { return; }
    _m.seeded = false;
    randomize();
}

function mt_mines_state() {
    var _rt = __mt_rt();
    if (_rt[$ "mines"] == undefined) { _rt.mines = { seeded: false }; }
    return _rt.mines;
}

// Host: the setting and a fresh seed each morning.
function mt_mines_host_set(_on) {
    if (!mt_is_host()) { return; }
    var _w = mt_world_state();
    _w.mines = _on;
    _w.time_sent_frame = -100000;
    if (_on) { mt_mines_host_make(); }
}

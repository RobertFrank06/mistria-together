// Mistria Together - MtProgress.gml: shared progress (museum, mine depth, animals).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Only systems whose place in the save is the world (gamedata) are shared; see
// IMPLEMENT.md "Shared state: where it lives". Messages: mu (museum items),
// md (deepest mine floor), an (animal care state).

function mt_progress_state() {
    var _rt = __mt_rt();
    if (_rt[$ "progress"] == undefined) {
        _rt.progress = { depth_sent: 0, animals: {}, scan_frame: 0, unlock_key: "" };
    }
    return _rt.progress;
}

function mt_progress_reset() {
    __mt_rt().progress = undefined;
}

// --- museum -------------------------------------------------------------------------------

function mt_progress_museum_list() {
    var _out = [];
    for (var _i = 0; _i < ItemId.LEN; _i++) {
        if (MUSEUM_PROGRESS[_i] == true) { array_push(_out, item_id_to_string(_i)); }
    }
    return _out;
}

// museum.donate_item event: tell everybody (the item is registered right after).
function mt_progress_on_donate(_ctx) {
    if (!mt_night_active()) { return; }
    try { mt_send(MT_TO_ALL, { t: "mu", l: [item_id_to_string(_ctx.item_id)] }); }
    catch (_e) { mmapi_warn_rate_limited("mt_mu", MT_MOD, "museum message failed: " + string(_e)); }
}

function mt_progress_apply_museum(_list) {
    if (!is_array(_list)) { return; }
    for (var _i = 0; _i < array_length(_list); _i++) {
        var _id = try_string_to_item_id(_list[_i]);
        if (_id != undefined && MUSEUM_PROGRESS[_id] != true) { register_item_to_museum(_id); }
    }
}

// --- mine depth ------------------------------------------------------------------------------

function mt_progress_apply_depth(_level) {
    if (is_numeric(_level) && _level > MAXIMUM_REACHED_DUNGEON_LEVEL) { MAXIMUM_REACHED_DUNGEON_LEVEL = _level; }
}

// --- animals ----------------------------------------------------------------------------------

function mt_progress_animals_scan() {
    var _p = mt_progress_state();
    var _list = get_all_animals();
    for (var _i = 0; _i < _list.count(); _i++) {
        var _a = _list.get(_i);
        var _key = string(_a.idx);
        var _now = (_a.has_been_pat ? 1 : 0) + (_a.has_eaten ? 2 : 0);
        var _was = _p.animals[$ _key];
        if (_was == undefined) { _p.animals[$ _key] = _now; continue; }
        if (_now != _was) {
            _p.animals[$ _key] = _now;
            mt_send(MT_TO_ALL, { t: "an", i: _a.idx, pat: _a.has_been_pat ? 1 : 0, eaten: _a.has_eaten ? 1 : 0 });
        }
    }
}

function mt_progress_apply_animal(_d) {
    var _a = find_animal(_d.i);
    if (_a == undefined) { return; }
    if (_d[$ "pat"] == 1) { _a.has_been_pat = true; }
    if (_d[$ "eaten"] == 1) { _a.has_eaten = true; }
    var _p = mt_progress_state();
    _p.animals[$ string(_d.i)] = (_a.has_been_pat ? 1 : 0) + (_a.has_eaten ? 2 : 0);
}

// --- world unlocks ------------------------------------------------------------------------------
// Bridges, repaired places and opened regions are the world mods whose
// requirements the host has met. A guest fulfils the same requirements with the
// game's own function, except the ones with a personal cost (gold, items).

function mt_progress_unlocked_list() {
    var _out = [];
    for (var _i = 0; _i < WorldMod.LEN; _i++) {
        if (world_mod_enabled(_i)) { array_push(_out, _i); }
    }
    return _out;
}

function mt_progress_fulfill_mod(_i) {
    var _req = WORLD_MODS[_i].requirements;
    if (!is_array(_req)) { return; }
    for (var _r = 0; _r < array_length(_req); _r++) {
        if (_req[_r] == undefined || (is_array(_req[_r]) && array_length(_req[_r]) == 0)) { continue; }
        if (_r == Requirement.HasGold || _r == Requirement.HasItem || _r == Requirement.SuppliedItems
            || _r == Requirement.ShippedItem || _r == Requirement.ShippedTag) { continue; }
        try { fulfill_requirement(_r, _req[_r]); }
        catch (_e) { mmapi_warn_rate_limited("mt_unlock", MT_MOD, "could not unlock world mod " + string(_i) + ": " + string(_e)); }
    }
}

function mt_progress_apply_unlocks(_list) {
    if (!is_array(_list)) { return; }
    for (var _k = 0; _k < array_length(_list); _k++) {
        var _i = _list[_k];
        if (is_numeric(_i) && _i >= 0 && _i < WorldMod.LEN && !world_mod_enabled(_i)) { mt_progress_fulfill_mod(_i); }
    }
}

// --- plumbing ---------------------------------------------------------------------------------

function mt_progress_tick() {
    var _rt = __mt_rt();
    var _p = mt_progress_state();
    if (!mt_night_active() || _rt.frame % 60 != 7) { return; }
    try {
        if (MAXIMUM_REACHED_DUNGEON_LEVEL > _p.depth_sent) {
            _p.depth_sent = MAXIMUM_REACHED_DUNGEON_LEVEL;
            mt_send(MT_TO_ALL, { t: "md", l: MAXIMUM_REACHED_DUNGEON_LEVEL });
        }
        mt_progress_animals_scan();
        if (mt_is_host()) {
            var _u = mt_progress_unlocked_list();
            var _key = json_stringify(_u);
            if (_key != _p.unlock_key) {
                _p.unlock_key = _key;
                mt_send(MT_TO_ALL, { t: "wu", l: _u });
            }
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_progress", MT_MOD, "progress scan failed: " + string(_e));
    }
}

// Host: a newcomer (and every morning) gets the whole picture.
function mt_progress_send_all(_to) {
    if (!mt_is_host()) { return; }
    try {
        mt_send(_to, { t: "mu", l: mt_progress_museum_list() });
        mt_send(_to, { t: "md", l: MAXIMUM_REACHED_DUNGEON_LEVEL });
        mt_send(_to, { t: "wu", l: mt_progress_unlocked_list() });
    } catch (_e) {
        mmapi_warn_rate_limited("mt_progress_all", MT_MOD, "progress snapshot failed: " + string(_e));
    }
}

function mt_progress_on_message(_peer, _t, _d) {
    try {
        switch (_t) {
            case "mu": mt_progress_apply_museum(_d[$ "l"]); break;
            case "md": mt_progress_apply_depth(_d[$ "l"]); break;
            case "wu": if (_peer.id == __mt_rt().host_id) { mt_progress_apply_unlocks(_d[$ "l"]); } break;
            case "an": mt_progress_apply_animal(_d); break;
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_progress_msg", MT_MOD, "could not apply " + string(_t) + ": " + string(_e));
    }
}

function mt_progress_dev_state() {
    var _items = 0;
    for (var _i = 0; _i < ItemId.LEN; _i++) { if (MUSEUM_PROGRESS[_i] == true) { _items += 1; } }
    return { museum: _items, depth: MAXIMUM_REACHED_DUNGEON_LEVEL };
}

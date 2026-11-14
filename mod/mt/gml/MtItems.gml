// Mistria Together - MtItems.gml: dropped items and chest locks.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dropped items: every stack dropped in a shared location gets an id and is
// shown to everybody there. The first player to pick one up gets it: the local
// pickup is held for a moment (the item's own kill timer) while the host
// decides. Chests and the shipping bin are open for one player at a time: the
// bed-style interaction takeover asks the host for a lock first.
// Messages: id (an item appeared), ic (claim), cg / cd (granted / denied),
// ix (gone), kl / kg / kd / kr (chest lock request / granted / denied / release).

function mt_items_state() {
    var _rt = __mt_rt();
    if (_rt[$ "items"] == undefined) {
        _rt.items = {
            counter: 0,
            dbg_events: 0,      // items.dropped events seen
            dbg_tagged: 0,      // stacks tagged
            tracked: {},        // gid -> { inst, claim }
            by_inst: {},        // string(instance id) -> gid
            drops: [],          // drops seen this frame, tagged next frame
            live: {},           // host: gid -> true while nobody has claimed it
            locks: {},          // host: chest key -> peer id
            held: "",           // chest key this player has locked
            held_node: undefined,
            ok_key: "",         // lock granted: let the next interaction through
            lock_wait: "",      // chest key being requested
        };
    }
    return _rt.items;
}

function mt_items_reset() {
    __mt_rt().items = undefined;
}

function mt_items_active() {
    return mt_night_active() && GRID != undefined && mt_sync_grid_shared(GRID);
}

// Every obj_item instance, as references that stay valid.
function mt_items_all() {
    var _out = [];
    var _n = instance_number(obj_item);
    for (var _i = 0; _i < _n; _i++) { array_push(_out, instance_find(obj_item, _i)); }
    return _out;
}

// --- dropped items ---------------------------------------------------------------------------

function mt_items_on_dropped(_ctx) {
    mt_items_state().dbg_events += 1;
    if (!mt_items_active()) { return; }
    array_push(mt_items_state().drops, { x: _ctx.x, y: _ctx.y });
}

function mt_items_serialize(_inst) {
    var _out = [];
    for (var _i = 0; _i < _inst.items.count(); _i++) { array_push(_out, _inst.items.get(_i).serialize()); }
    return _out;
}

// Tag the instances a drop just created and announce them.
function mt_items_tag_new() {
    var _it = mt_items_state();
    var _rt = __mt_rt();
    var _drops = _it.drops;
    _it.drops = [];
    if (array_length(_drops) == 0) { return; }
    var _fresh = [];
    var _all = mt_items_all();
    for (var _a = 0; _a < array_length(_all); _a++) {
        var _cand = _all[_a];
        if (_it.by_inst[$ string(_cand)] != undefined) { continue; }
        for (var _d = 0; _d < array_length(_drops); _d++) {
            if (point_distance(_cand.x, _cand.y, _drops[_d].x, _drops[_d].y) < 48) { array_push(_fresh, _cand); break; }
        }
    }
    for (var _f = 0; _f < array_length(_fresh); _f++) {
        var _inst = _fresh[_f];
        _it.counter += 1;
        var _gid = string(_rt.self_id) + "-" + string(_it.counter);
        _it.by_inst[$ string(_inst)] = _gid;
        _it.dbg_tagged += 1;
        _it.tracked[$ _gid] = { inst: _inst, claim: "none" };
        if (mt_is_host()) { _it.live[$ _gid] = true; }
        try {
            mt_send(MT_TO_ALL, {
                t: "id", gid: _gid, g: mt_sync_grid_ref(GRID), x: _inst.x, y: _inst.y,
                fx: _inst.final_x, fy: _inst.final_y, items: mt_items_serialize(_inst),
            });
        } catch (_e) { mmapi_warn_rate_limited("mt_items_id", MT_MOD, "could not announce a dropped item: " + string(_e)); }
    }
}

function mt_items_on_id(_peer, _d) {
    var _it = mt_items_state();
    if (mt_is_host()) { _it.live[$ _d.gid] = true; }
    if (_it.tracked[$ _d.gid] != undefined) { return; }
    var _grid = mt_sync_find_grid(_d.g);
    if (_grid == undefined) { return; }
    var _items = [];
    for (var _i = 0; _i < array_length(_d.items); _i++) { array_push(_items, deserialize_live_item(_d.items[_i])); }
    if (_grid != GRID) {
        // Nobody is there: the item waits for the next visit.
        _grid.lost_items.push({ x: _d.x, y: _d.y, items: ListFromArray(_items) });
        return;
    }
    var _inst = instance_create_layer(_d.x, _d.y, "Instances", obj_item);
    _inst.final_x = _d.fx;
    _inst.final_y = _d.fy;
    _inst.setup(ListFromArray(_items));
    _it.by_inst[$ string(_inst)] = _d.gid;
    _it.tracked[$ _d.gid] = { inst: _inst, claim: "none" };
}

// The local player is collecting an item: hold it until the host agrees.
function mt_items_scan_pickups() {
    var _it = mt_items_state();
    var _names = struct_get_names(_it.tracked);
    for (var _i = 0; _i < array_length(_names); _i++) {
        var _gid = _names[_i];
        var _t = _it.tracked[$ _gid];
        if (!instance_exists(_t.inst)) { struct_remove(_it.tracked, _gid); continue; }
        var _inst = _t.inst;
        try {
            if (_inst.kill_timer == -1 || _t.claim == "granted") { continue; }
            var _kt = _inst.kill_target;
            if (_kt == undefined || !instance_exists(_kt) || _kt.object_index != obj_ari) { continue; }
        } catch (_ek) { continue; }
        if (_t.claim == "none") {
            _t.claim = "pending";
            if (mt_is_host()) { mt_items_host_claim(_gid, __mt_rt().self_id); }
            else { mt_send(MT_TO_HOST, { t: "ic", gid: _gid }); }
        }
        if (_t.claim == "pending") { _inst.kill_timer = max(_inst.kill_timer, 3); }
    }
}

function mt_items_host_claim(_gid, _who) {
    var _it = mt_items_state();
    var _rt = __mt_rt();
    var _granted = _it.live[$ _gid] == true;
    if (_granted) {
        struct_remove(_it.live, _gid);
        mt_send(MT_TO_ALL, { t: "ix", gid: _gid, by: _who });
    }
    if (_who == _rt.self_id) { mt_items_answer(_gid, _granted); }
    else if (_granted) { mt_send(_who, { t: "cg", gid: _gid }); }
    else { mt_send(_who, { t: "cd", gid: _gid }); }
}

function mt_items_answer(_gid, _granted) {
    var _t = mt_items_state().tracked[$ _gid];
    if (_t == undefined || !instance_exists(_t.inst)) { return; }
    if (_granted) { _t.claim = "granted"; return; }
    // Somebody else got there first: the item just goes away.
    _t.inst.picked_up = true;
    instance_destroy(_t.inst);
    struct_remove(mt_items_state().tracked, _gid);
}

// --- chest locks ------------------------------------------------------------------------------

function mt_items_chest_key(_node) {
    return json_stringify(mt_sync_grid_ref(GRID)) + "@" + string(_node.top_left_x) + ":" + string(_node.top_left_y);
}

// object.interact: storage chests and the shipping bin are used by one player at a time.
function mt_items_on_interact(_node) {
    if (!mt_night_active()) { return undefined; }
    try {
        if (_node.prototype.interaction_chest == undefined || !mt_sync_grid_shared(GRID)) { return undefined; }
        var _it = mt_items_state();
        var _key = mt_items_chest_key(_node);
        if (_it.ok_key == _key) { _it.ok_key = ""; _it.held = _key; _it.held_node = _node; return undefined; }
        if (_it.held == _key) { return undefined; }
        if (_it.lock_wait != "") { return true; }
        if (mt_is_host()) {
            var _holder = _it.locks[$ _key];
            if (_holder != undefined && _holder != __mt_rt().self_id) {
                mt_ui_toast("In use by " + mt_peer_name(_holder));
                return true;
            }
            _it.locks[$ _key] = __mt_rt().self_id;
            _it.held = _key;
            _it.held_node = _node;
            return undefined;
        }
        _it.lock_wait = _key;
        _it.lock_node = _node;
        mt_send(MT_TO_HOST, { t: "kl", k: _key });
        return true;
    } catch (_e) {
        mmapi_warn_rate_limited("mt_items_interact", MT_MOD, "chest lock failed: " + string(_e));
        return undefined;
    }
}

function mt_items_on_lock_answer(_granted, _by) {
    var _it = mt_items_state();
    var _key = _it.lock_wait;
    var _node = _it.lock_node;
    _it.lock_wait = "";
    if (_key == "") { return; }
    if (!_granted) { mt_ui_toast("In use by " + mt_peer_name(_by)); return; }
    _it.ok_key = _key;
    try { interact(_node); } catch (_e) { mmapi_warn_rate_limited("mt_items_open", MT_MOD, "could not open the chest: " + string(_e)); }
    _it.ok_key = "";
}

// Release the lock once the storage menu is gone and push the contents out right away.
function mt_items_check_release() {
    var _it = mt_items_state();
    if (_it.held == "" || ANCHOR.get_menu(Menu.Storage) != undefined) { return; }
    var _key = _it.held;
    var _node = _it.held_node;
    _it.held = "";
    _it.held_node = undefined;
    try {
        if (_node != undefined) {
            var _s = mt_sync_state();
            var _k = string(_node.top_left_x) + ":" + string(_node.top_left_y);
            struct_remove(_s.sig_frame, _k);
            mt_sync_check_signature(_s, GRID, _node, _k, __mt_rt().frame);
        }
    } catch (_e) {}
    if (mt_is_host()) { struct_remove(_it.locks, _key); }
    else { mt_send(MT_TO_HOST, { t: "kr", k: _key }); }
}

// A player left: their locks are released.
function mt_items_on_leave(_id) {
    var _it = __mt_rt()[$ "items"];
    if (_it == undefined || !mt_is_host()) { return; }
    var _names = struct_get_names(_it.locks);
    for (var _i = 0; _i < array_length(_names); _i++) {
        if (_it.locks[$ _names[_i]] == _id) { struct_remove(_it.locks, _names[_i]); }
    }
}

// --- plumbing -----------------------------------------------------------------------------------

function mt_items_tick() {
    if (!mt_night_active()) { return; }
    try { mt_items_tag_new(); }
    catch (_e1) { mmapi_warn_rate_limited("mt_items_tag", MT_MOD, "items tag failed: " + string(_e1)); }
    try { mt_items_scan_pickups(); }
    catch (_e2) { mmapi_warn_rate_limited("mt_items_scan", MT_MOD, "items scan failed: " + string(_e2)); }
    try { mt_items_check_release(); }
    catch (_e3) { mmapi_warn_rate_limited("mt_items_release", MT_MOD, "chest release failed: " + string(_e3)); }
}

function mt_items_on_message(_peer, _t, _d) {
    var _it = mt_items_state();
    var _rt = __mt_rt();
    try {
        switch (_t) {
            case "id": mt_items_on_id(_peer, _d); break;
            case "ic": if (mt_is_host()) { mt_items_host_claim(_d.gid, _peer.id); } break;
            case "cg": mt_items_answer(_d.gid, true); break;
            case "cd": mt_items_answer(_d.gid, false); break;
            case "ix":
                if (_d.by != _rt.self_id) {
                    var _tr = _it.tracked[$ _d.gid];
                    if (_tr != undefined && instance_exists(_tr.inst)) { _tr.inst.picked_up = true; instance_destroy(_tr.inst); }
                    struct_remove(_it.tracked, _d.gid);
                }
                break;
            case "kl":
                if (!mt_is_host()) { break; }
                var _holder = _it.locks[$ _d.k];
                if (_holder == undefined || _holder == _peer.id) {
                    _it.locks[$ _d.k] = _peer.id;
                    mt_send(_peer.id, { t: "kg", k: _d.k });
                } else {
                    mt_send(_peer.id, { t: "kd", k: _d.k, by: _holder });
                }
                break;
            case "kg": mt_items_on_lock_answer(true, -1); break;
            case "kd": mt_items_on_lock_answer(false, _d[$ "by"] ?? -1); break;
            case "kr": if (mt_is_host() && _it.locks[$ _d.k] == _peer.id) { struct_remove(_it.locks, _d.k); } break;
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_items_msg", MT_MOD, "could not handle " + string(_t) + ": " + string(_e));
    }
}

function mt_items_dev_state() {
    var _it = mt_items_state();
    return { events: _it.dbg_events, tagged: _it.dbg_tagged, active: mt_items_active(), tracked: array_length(struct_get_names(_it.tracked)), held: _it.held, menu: ANCHOR.get_menu(Menu.Storage) != undefined };
}

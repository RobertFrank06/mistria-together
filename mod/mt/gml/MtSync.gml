// Mistria Together - MtSync.gml: one shared farm.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The host's save is the world. Sharing it has two parts:
//
//   Snapshots. When a guest joins, and again every morning, the host
//   serializes its grids with the game's own save code and ships them through
//   the companion as a compressed file. The guest loads them with the game's
//   own load code. Anything this file does not understand is still carried,
//   because it is the save format itself.
//
//   Live changes. Between snapshots every player watches the grid they are
//   standing in and reports what changed: objects placed, removed or altered,
//   soil tilled, soil watered. Watching is done by comparing the grid with a
//   private copy, a slice at a time, so it costs microseconds per frame and
//   needs no hooks into the hundreds of things that can touch a tile. The area
//   around the player is compared several times a second (that is where a
//   player's own actions land); the rest of the grid is swept every few
//   seconds to catch far-reaching effects such as spells.
//
// Changes are applied with the same grid calls the game uses, to whichever
// grid they belong to, so they are waiting for you when you walk back in.

#macro MT_SYNC_NEAR_RADIUS 12
#macro MT_SYNC_NEAR_INTERVAL 4
#macro MT_SYNC_SIG_INTERVAL 10
#macro MT_SYNC_SWEEP_CELLS 600
#macro MT_SYNC_TERRAIN_BATCH 120

function mt_sync_state() {
    var _rt = __mt_rt();
    if (_rt[$ "sync"] == undefined) { mt_sync_reset(); }
    return _rt.sync;
}

function mt_sync_reset() {
    var _rt = __mt_rt();
    _rt.sync = {
        // snapshots
        snap_seq: 0,
        want_snapshot: false,       // guest: waiting for the host's world
        requested_frame: -100000,
        pending: {},                // guest: snapshot parts received so far
        adopted: false,             // guest: running on the host's world
        backed_up: false,
        send_to: [],                // host: peers waiting for a snapshot
        send_all: false,
        applied: 0,
        // live change detection (for the grid we are standing in)
        grid: undefined,
        oid: undefined,
        rx: undefined,
        ry: undefined,
        gk: undefined,
        wet: undefined,
        live: {},                   // "x:y" of an object's top-left -> object id
        sigs: {},
        sig_frame: {},
        cursor: 0,
        terrain_out: [],
        // statistics for the dev overlay / tests
        sent: 0,
        received: 0,
        scan_us: 0,
    };
}

function mt_sync_enabled() {
    return mt_config().sync_world;
}

// ---------------------------------------------------------------------------
// Session events
// ---------------------------------------------------------------------------

function mt_sync_on_online() {
    var _s = mt_sync_state();
    if (mt_is_guest() && mt_sync_enabled()) {
        _s.want_snapshot = true;
    }
}

function mt_sync_on_peer_joined(_id) {
}

// The host's calendar moved on (it slept): a fresh snapshot follows.
function mt_sync_on_host_day(_cal) {
    var _s = mt_sync_state();
    if (!_s.adopted) {
        _s.want_snapshot = true;
    }
}

// game.new_day on this machine.
function mt_sync_on_new_day(_ctx) {
    var _rt = __mt_rt();
    if (!_rt.online || !mt_sync_enabled()) { return; }
    var _s = mt_sync_state();
    if (mt_is_host()) {
        // Crops grew, weather rolled, shops restocked: everyone gets the new morning.
        _s.send_all = true;
        _s.grid = undefined;
    } else {
        // A guest cannot end the day alone; fall back in line with the host.
        _s.want_snapshot = true;
        _s.requested_frame = -100000;
    }
}

function mt_sync_save_guard(_ctx) {
    return undefined;
}

// ---------------------------------------------------------------------------
// Snapshots: host side
// ---------------------------------------------------------------------------

function mt_sync_grid_data(_grid) {
    var _blob = create_grid_serialization_data(_grid);
    var _terrain = _blob[$ "terrain_buffer"];
    return {
        terrain: _terrain,
        data: {
            object_list: _blob.object_list,
            inventories: _blob.inventories,
            size_x: _blob.size_x,
            size_y: _blob.size_y,
            location_id: _blob.location_id,
            dyn_index: _blob.dyn_index,
        },
    };
}

function mt_sync_send_snapshot(_to) {
    var _rt = __mt_rt();
    var _s = mt_sync_state();
    var _started = get_timer();
    _s.snap_seq += 1;
    var _n = _s.snap_seq;
    var _has_terrain = false;

    var _locations = [];
    for (var _i = 0; _i < LocationId.LEN; _i++) {
        if (_i == LocationId.Dungeon || GRIDS[_i] == undefined || LOCATIONS[_i].serializable == false) { continue; }
        var _entry = mt_sync_grid_data(GRIDS[_i]);
        if (_entry.terrain != undefined) {
            if (_i == LocationId.Farm && !_has_terrain) {
                buffer_save(_entry.terrain, _rt.dir + "/blob_out_" + string(_n) + "_terrain.bin");
                _has_terrain = true;
            }
            buffer_delete(_entry.terrain);
        }
        array_push(_locations, { loc: _i, data: _entry.data });
    }

    var _dyn = [];
    if (DYNAMIC_GRIDS != undefined) {
        for (var _d = 0; _d < DYNAMIC_GRIDS.count(); _d++) {
            var _dg = DYNAMIC_GRIDS.get(_d);
            if (_dg == undefined) {
                array_push(_dyn, 0);
                continue;
            }
            var _dentry = mt_sync_grid_data(_dg);
            if (_dentry.terrain != undefined) { buffer_delete(_dentry.terrain); }
            array_push(_dyn, _dentry.data);
        }
    }

    var _snapshot = {
        v: 1,
        cal: CALENDAR.time,
        clk: CLOCK.time,
        weather: WEATHER.serialize(),
        farm_expanded: FARM_EXPANDED,
        home_upgrade: DECOR.size_upgrade,
        floorings: DECOR.serialize_floorings(),
        wallpapers: DECOR.serialize_wallpapers(),
        max_dungeon: MAXIMUM_REACHED_DUNGEON_LEVEL,
        locations: _locations,
        dyn: _dyn,
    };
    var _file = "blob_out_" + string(_n) + "_world.json";
    save_text_file(_rt.dir + "/" + _file, json_stringify(_snapshot));

    if (_has_terrain) {
        mt_send_link({ t: "blob", to: _to, kind: "terrain", file: "blob_out_" + string(_n) + "_terrain.bin", meta: { snap: _n } });
    }
    mt_send_link({ t: "blob", to: _to, kind: "world", file: _file, meta: { snap: _n, terrain: _has_terrain ? 1 : 0 } });
    mt_log("sent world snapshot " + string(_n) + " (" + string(array_length(_locations)) + " locations, "
        + string(array_length(_dyn)) + " interiors) in " + string(round((get_timer() - _started) / 1000)) + " ms");
}

// ---------------------------------------------------------------------------
// Snapshots: guest side
// ---------------------------------------------------------------------------

function mt_sync_on_blob(_d) {
    var _rt = __mt_rt();
    var _s = mt_sync_state();
    var _path = _rt.dir + "/" + string(_d[$ "file"]);
    var _meta = _d[$ "meta"];
    if (_d[$ "from"] != _rt.host_id || !mt_is_guest() || !mt_sync_enabled() || !is_struct(_meta)) {
        try { file_delete(_path); } catch (_e) {}
        return;
    }
    var _snap = _meta[$ "snap"];
    if (_s.pending[$ "snap"] != _snap) {
        mt_sync_drop_pending();
        _s.pending = { snap: _snap, world: undefined, terrain: undefined, need_terrain: undefined };
    }
    if (_d[$ "kind"] == "terrain") {
        _s.pending.terrain = _path;
    } else if (_d[$ "kind"] == "world") {
        _s.pending.world = _path;
        _s.pending.need_terrain = _meta[$ "terrain"] == 1;
    }
}

function mt_sync_drop_pending() {
    var _s = mt_sync_state();
    var _p = _s.pending;
    try {
        if (_p[$ "world"] != undefined && file_exists(_p.world)) { file_delete(_p.world); }
        if (_p[$ "terrain"] != undefined && file_exists(_p.terrain)) { file_delete(_p.terrain); }
    } catch (_e) {}
    _s.pending = {};
}

// Keep a copy of the guest's own save before its world is replaced.
function mt_sync_backup_save() {
    var _s = mt_sync_state();
    if (_s.backed_up) { return; }
    try {
        var _path = Game.last_serde_path;
        if (!is_string(_path) || !file_exists(_path)) { return; }
        var _dir = mmapi_config_dir(MT_MOD) + "/backups";
        if (!directory_exists(_dir)) { directory_create(_dir); }
        var _dest = _dir + "/" + filename_name(_path);
        // This backup represents the guest's original farm. It must survive
        // later reconnects, when the active save already contains the host's.
        if (file_exists(_dest)) {
            _s.backed_up = true;
            mt_log("preserved existing save backup " + _dest);
            return;
        }
        if (!file_copy(_path, _dest) || !file_exists(_dest)) {
            mt_warn("could not verify save backup at " + _dest);
            return;
        }
        _s.backed_up = true;
        mt_log("backed up " + _path + " before adopting the host's world");
    } catch (_e) {
        mt_warn("could not back up the save: " + string(_e));
    }
}

function mt_sync_inventories(_arr) {
    var _out = [];
    if (!is_array(_arr)) { return _out; }
    for (var _i = 0; _i < array_length(_arr); _i++) {
        var _inv = Inventory(array_length(_arr[_i]));
        _inv.deserialize(_arr[_i]);
        array_push(_out, _inv);
    }
    return _out;
}

function mt_sync_apply_snapshot(_snap, _terrain_buffer) {
    var _started = get_timer();
    mt_sync_backup_save();

    // Farm animals hold references into the grids that are about to go away.
    with (obj_player_animal) { instance_destroy(); }

    var _dyn = _snap[$ "dyn"];
    if (is_array(_dyn)) {
        var _count = array_length(_dyn);
        DYNAMIC_GRIDS = ListFromArray(array_create(_count, undefined));
        for (var _d = 0; _d < _count; _d++) {
            var _entry = _dyn[_d];
            if (!is_struct(_entry)) { continue; }
            try {
                var _dgrid = initialize_grid(string_to_location_id(_entry.location_id), _entry.dyn_index == -1 ? undefined : _entry.dyn_index);
                DYNAMIC_GRIDS.set(_d, _dgrid);
                _dgrid.load(_entry);
                _dgrid.is_setup = true;
            } catch (_e) {
                mt_warn("snapshot: interior " + string(_d) + " failed: " + string(_e));
            }
        }
    }

    var _home_upgrade = _snap[$ "home_upgrade"];
    var _locations = _snap.locations;
    var _applied = 0;
    for (var _i = 0; _i < array_length(_locations); _i++) {
        var _loc = _locations[_i].loc;
        var _data = _locations[_i].data;
        if (!is_numeric(_loc) || _loc < 0 || _loc >= LocationId.LEN || _loc == LocationId.Dungeon) { continue; }
        try {
            // Mirrors the grid section of the game's own load_game().
            var _grid = initialize_grid(_loc);
            if (_loc == LocationId.PlayerHome) {
                DECOR.size_upgrade = -1;
                DECOR.apply_house_upgrade(_grid, _home_upgrade == undefined ? HomeUpgrade.Small : _home_upgrade);
            }
            if (_loc == LocationId.Farm) {
                room_data_initialize_post_init_flags(location_id_to_gm_room(_grid.location_id), _grid.node_flags);
            } else if (_loc == LocationId.PriestessQuarters) {
                setup_priestess_quarters(_grid);
            }
            _grid.load(_data, _loc == LocationId.Farm ? _terrain_buffer : undefined);
            load_npc_farms(_grid);
            _grid.is_setup = true;
            GRIDS[_loc] = _grid;
            _applied += 1;
        } catch (_e2) {
            mt_warn("snapshot: location " + string(_loc) + " failed: " + string(_e2));
        }
    }
    global.__buildings = undefined;

    try {
        if (_snap[$ "farm_expanded"] != undefined) { FARM_EXPANDED = _snap.farm_expanded; }
        if (_snap[$ "floorings"] != undefined) { DECOR.floorings = deserialize_floorings(_snap.floorings); }
        if (_snap[$ "wallpapers"] != undefined) { DECOR.wallpapers = deserialize_wallpapers(_snap.wallpapers); }
        if (is_numeric(_snap[$ "max_dungeon"])) {
            MAXIMUM_REACHED_DUNGEON_LEVEL = max(MAXIMUM_REACHED_DUNGEON_LEVEL, _snap.max_dungeon);
        }
        if (is_numeric(_snap[$ "cal"])) { CALENDAR.time = _snap.cal; }
        if (is_numeric(_snap[$ "clk"])) { CLOCK.time = int64(_snap.clk); }
        if (_snap[$ "weather"] != undefined) {
            WEATHER.deserialize(_snap.weather);
            WEATHER.set_weather(WEATHER.weather);
        }
    } catch (_e3) {
        mt_warn("snapshot: world header failed: " + string(_e3));
    }

    // Re-enter the room we are standing in so it is rebuilt from the new grid.
    var _was = GRID;
    if (_was != undefined && _was.location_id != LocationId.Dungeon) {
        var _dyn_index = _was.dyn_index;
        var _target = undefined;
        if (_dyn_index != undefined) {
            _target = DYNAMIC_GRIDS.get(_dyn_index);
            if (_target == undefined || _target.location_id != _was.location_id) {
                // The interior we stood in does not exist in the host's world.
                _dyn_index = undefined;
                _target = GRIDS[LocationId.Farm];
            }
        } else {
            _target = GRIDS[_was.location_id];
        }
        // GRID itself is left alone: the room swap installs the new grid, and
        // until then the player must keep colliding with objects that still
        // have renderers.
        var _itinerary = TaxiItinerary(location_id_to_gm_room(_target.location_id), _dyn_index);
        _itinerary.set_instant(true);
        if (_target.location_id == _was.location_id) {
            var _pos = mt_sync_free_spot(_target, obj_ari.x, obj_ari.y);
            _itinerary.set_exact_position(_pos.x, _pos.y);
            _itinerary.set_arrival_callback(mt_sync_after_taxi, [_pos.x, _pos.y, obj_ari.dir]);
        }
        TAXI.taxi_player(_itinerary);
    }

    var _s = mt_sync_state();
    _s.adopted = true;
    _s.applied += 1;
    _s.grid = undefined;    // re-baseline change detection against the new grid
    mt_log("applied world snapshot (" + string(_applied) + "/" + string(array_length(_locations)) + " locations) in "
        + string(round((get_timer() - _started) / 1000)) + " ms");
}

function mt_sync_after_taxi(_x, _y, _dir) {
    if (!instance_exists(obj_ari)) { return; }
    obj_ari.x = _x;
    obj_ari.y = _y;
    obj_ari.face_dir(_dir);
}

// The host may have built something where we are standing.
function mt_sync_free_spot(_grid, _x, _y) {
    for (var _r = 0; _r <= 96; _r += 8) {
        for (var _dy = -_r; _dy <= _r; _dy += 8) {
            for (var _dx = -_r; _dx <= _r; _dx += 8) {
                if (_r > 0 && abs(_dx) != _r && abs(_dy) != _r) { continue; }
                var _ni = _grid.try_node_index_for_cell((_x + _dx) div OBJECT_CELL_SIZE, (_y + _dy) div OBJECT_CELL_SIZE);
                if (_ni == undefined) { continue; }
                if (_grid.node_object_id[_ni] == undefined) { return { x: _x + _dx, y: _y + _dy }; }
            }
        }
    }
    return { x: _x, y: _y };
}

function mt_sync_try_apply_pending() {
    var _s = mt_sync_state();
    var _p = _s.pending;
    if (_p[$ "world"] == undefined || _p[$ "need_terrain"] == undefined) { return; }
    if (_p.need_terrain && _p.terrain == undefined) { return; }
    // Not in the middle of a room change, cutscene or menu-less pause.
    if (!mt_in_world() || TAXI.itinerary != undefined) { return; }

    var _snap = try_read_json_file(_p.world, undefined, false);
    var _buffer = undefined;
    try {
        if (_p.need_terrain && file_exists(_p.terrain)) { _buffer = buffer_load(_p.terrain); }
    } catch (_e) { _buffer = undefined; }
    mt_sync_drop_pending();
    if (!is_struct(_snap) || !is_array(_snap[$ "locations"])) {
        mt_warn("world snapshot was unreadable, asking again");
        _s.want_snapshot = true;
        _s.requested_frame = -100000;
        if (_buffer != undefined) { buffer_delete(_buffer); }
        return;
    }
    var _first = !_s.adopted;
    try {
        mt_sync_apply_snapshot(_snap, _buffer);
        mt_ui_toast(_first ? "Loaded " + mt_peer_name(__mt_rt().host_id) + "'s world" : "A new day begins");
    } catch (_e2) {
        mt_warn("applying the world snapshot failed: " + string(_e2));
    }
    if (_buffer != undefined) { buffer_delete(_buffer); }
    _s.want_snapshot = false;
}

// ---------------------------------------------------------------------------
// Live changes: detection
// ---------------------------------------------------------------------------

function mt_sync_grid_ref(_grid) {
    return [_grid.location_id, _grid.dyn_index == undefined ? -1 : _grid.dyn_index];
}

function mt_sync_find_grid(_ref) {
    if (!is_array(_ref) || array_length(_ref) < 2) { return undefined; }
    var _loc = _ref[0];
    var _dyn = _ref[1];
    if (!is_numeric(_loc) || !is_numeric(_dyn)) { return undefined; }
    if (_dyn >= 0) {
        if (DYNAMIC_GRIDS == undefined || _dyn >= DYNAMIC_GRIDS.count()) { return undefined; }
        var _g = DYNAMIC_GRIDS.get(_dyn);
        return (_g != undefined && _g.location_id == _loc) ? _g : undefined;
    }
    if (_loc < 0 || _loc >= LocationId.LEN || _loc == LocationId.Dungeon || GRIDS == undefined) { return undefined; }
    return GRIDS[_loc];
}

// Whether changes to this grid are shared at all.
function mt_sync_grid_shared(_grid) {
    return _grid != undefined && _grid.location_id != LocationId.Dungeon && _grid.is_setup;
}

function mt_sync_baseline(_grid) {
    var _s = mt_sync_state();
    var _n = _grid.node_len;
    _s.grid = _grid;
    _s.oid = array_create(_n, undefined);
    _s.rx = array_create(_n, undefined);
    _s.ry = array_create(_n, undefined);
    _s.gk = array_create(_n, undefined);
    _s.wet = array_create(_n, false);
    array_copy(_s.oid, 0, _grid.node_object_id, 0, _n);
    var _ids = _grid.node_object_id;
    var _parents = _grid.node_parent;
    var _live = {};
    for (var _i = 0; _i < _n; _i++) {
        if (_ids[_i] != undefined) {
            var _px = _parents[_i].top_left_x;
            var _py = _parents[_i].top_left_y;
            _s.rx[_i] = _px;
            _s.ry[_i] = _py;
            _live[$ (string(_px) + ":" + string(_py))] = _ids[_i];
        }
    }
    _s.live = _live;
    array_copy(_s.gk, 0, _grid.node_terrain_ground_kind, 0, _n);
    array_copy(_s.wet, 0, _grid.node_terrain_is_watered, 0, _n);
    _s.sigs = {};
    _s.sig_frame = {};
    _s.cursor = 0;
    _s.terrain_out = [];
}

// Copy the live state of a block of cells into the private copy, so a change
// we applied ourselves is not reported back as a local one.
function mt_sync_rebaseline_rect(_grid, _x0, _y0, _x1, _y1) {
    var _s = mt_sync_state();
    if (_s.grid != _grid) { return; }
    var _w = _grid.dims.x;
    _x0 = max(0, _x0);
    _y0 = max(0, _y0);
    _x1 = min(_w - 1, _x1);
    _y1 = min(_grid.dims.y - 1, _y1);
    for (var _yy = _y0; _yy <= _y1; _yy++) {
        for (var _xx = _x0; _xx <= _x1; _xx++) {
            var _ni = _yy * _w + _xx;
            var _o = _grid.node_object_id[_ni];
            _s.oid[_ni] = _o;
            _s.rx[_ni] = _o == undefined ? undefined : _grid.node_parent[_ni].top_left_x;
            _s.ry[_ni] = _o == undefined ? undefined : _grid.node_parent[_ni].top_left_y;
            _s.gk[_ni] = _grid.node_terrain_ground_kind[_ni];
            _s.wet[_ni] = _grid.node_terrain_is_watered[_ni];
        }
    }
}

function mt_sync_object_synced(_oid) {
    // Buildings carry whole interiors and are placed overnight: they travel
    // with the morning snapshot instead.
    return object_id_to_object_category(_oid) != ObjectCategory.Building;
}

function mt_sync_object_data(_node) {
    var _invs = List();
    var _obj = create_grid_object_serialization_data(_node, _invs);
    return { o: _obj, iv: _invs.to_array() };
}

function mt_sync_emit_object(_grid, _node) {
    if (!mt_sync_object_synced(_node.object_id)) { return undefined; }
    var _s = mt_sync_state();
    var _data = undefined;
    try {
        _data = mt_sync_object_data(_node);
    } catch (_e) {
        mmapi_warn_rate_limited("mt_sync_ser", MT_MOD, "could not serialize an object: " + string(_e));
        return undefined;
    }
    var _sig = json_stringify(_data);
    mt_send(MT_TO_ALL, { t: "wo", g: mt_sync_grid_ref(_grid), x: _node.top_left_x, y: _node.top_left_y, o: _data.o, iv: _data.iv });
    _s.sent += 1;
    return _sig;
}

// Find a cell occupied by the object whose footprint starts at (_x, _y). The
// top-left cell itself is often empty (a tree only blocks its trunk).
function mt_sync_find_by_root(_grid, _x, _y) {
    var _w = _grid.dims.x;
    var _x1 = min(_w - 1, _x + 12);
    var _y1 = min(_grid.dims.y - 1, _y + 12);
    for (var _yy = max(0, _y); _yy <= _y1; _yy++) {
        for (var _xx = max(0, _x); _xx <= _x1; _xx++) {
            var _ni = _yy * _w + _xx;
            if (_grid.node_object_id[_ni] == undefined) { continue; }
            var _p = _grid.node_parent[_ni];
            if (_p.top_left_x == _x && _p.top_left_y == _y) { return _ni; }
        }
    }
    return undefined;
}

// Compare one cell against the private copy and report what changed.
function mt_sync_scan_cell(_s, _grid, _ni, _xx, _yy) {
    var _oid = _grid.node_object_id[_ni];
    var _rx = undefined;
    var _ry = undefined;
    if (_oid != undefined) {
        // An object's identity is the top-left cell of its footprint.
        var _parent = _grid.node_parent[_ni];
        _rx = _parent.top_left_x;
        _ry = _parent.top_left_y;
    }
    var _old = _s.oid[_ni];
    if (_oid != _old || _rx != _s.rx[_ni] || _ry != _s.ry[_ni]) {
        var _old_key = _old == undefined ? undefined : string(_s.rx[_ni]) + ":" + string(_s.ry[_ni]);
        var _new_key = _oid == undefined ? undefined : string(_rx) + ":" + string(_ry);
        var _old_x = _s.rx[_ni];
        var _old_y = _s.ry[_ni];
        _s.oid[_ni] = _oid;
        _s.rx[_ni] = _rx;
        _s.ry[_ni] = _ry;
        // Objects never shrink: a cell that stopped belonging to one means
        // the whole object is gone. `live` makes sure it is reported once.
        if (_old_key != undefined && _old_key != _new_key && _s.live[$ _old_key] != undefined) {
            struct_remove(_s.live, _old_key);
            struct_remove(_s.sigs, _old_key);
            if (mt_sync_object_synced(_old)) {
                mt_send(MT_TO_ALL, { t: "wd", g: mt_sync_grid_ref(_grid), x: _old_x, y: _old_y });
                _s.sent += 1;
            }
        }
        if (_new_key != undefined && _s.live[$ _new_key] != _oid) {
            _s.live[$ _new_key] = _oid;
            var _sig = mt_sync_emit_object(_grid, _grid.node_parent[_ni]);
            if (_sig != undefined) {
                _s.sigs[$ _new_key] = _sig;
                _s.sig_frame[$ _new_key] = __mt_rt().frame;
            }
        }
    }
    // Soil lives on a 2x2 lattice; the even cell speaks for its block.
    if ((_xx & 1) == 0 && (_yy & 1) == 0) {
        var _gk = _grid.node_terrain_ground_kind[_ni];
        var _wet = _grid.node_terrain_is_watered[_ni];
        if (_gk != _s.gk[_ni] || _wet != _s.wet[_ni]) {
            _s.gk[_ni] = _gk;
            _s.wet[_ni] = _wet;
            array_push(_s.terrain_out, [_xx, _yy, _gk == undefined ? -1 : _gk, _wet ? 1 : 0]);
        }
    }
}

// Objects next to the player can change without moving (a tree losing
// hit points, a chest gaining items): compare their serialized form.
function mt_sync_scan_signatures(_s, _grid, _cx, _cy) {
    var _frame = __mt_rt().frame;
    var _w = _grid.dims.x;
    var _x0 = max(0, _cx - MT_SYNC_NEAR_RADIUS);
    var _y0 = max(0, _cy - MT_SYNC_NEAR_RADIUS);
    var _x1 = min(_w - 1, _cx + MT_SYNC_NEAR_RADIUS);
    var _y1 = min(_grid.dims.y - 1, _cy + MT_SYNC_NEAR_RADIUS);
    var _seen = {};
    for (var _yy = _y0; _yy <= _y1; _yy++) {
        for (var _xx = _x0; _xx <= _x1; _xx++) {
            var _ni = _yy * _w + _xx;
            var _oid = _grid.node_object_id[_ni];
            if (_oid == undefined) { continue; }
            var _p = _grid.node_parent[_ni];
            var _key = string(_p.top_left_x) + ":" + string(_p.top_left_y);
            if (_seen[$ _key] != undefined) { continue; }
            _seen[$ _key] = true;
            if (!mt_sync_object_synced(_oid)) { continue; }
            var _sig = undefined;
            try { _sig = json_stringify(mt_sync_object_data(_p)); } catch (_e) { continue; }
            var _known = _s.sigs[$ _key];
            if (_known == undefined) {
                _s.sigs[$ _key] = _sig;
            } else if (_known != _sig) {
                // At most two reports a second for any one object, in case
                // something in it ticks every frame.
                var _last = _s.sig_frame[$ _key];
                if (_last != undefined && _frame - _last < 30) { continue; }
                _s.sig_frame[$ _key] = _frame;
                _s.sigs[$ _key] = mt_sync_emit_object(_grid, _p) ?? _sig;
            }
        }
    }
}

function mt_sync_scan() {
    var _rt = __mt_rt();
    var _s = mt_sync_state();
    var _grid = GRID;
    if (!mt_sync_grid_shared(_grid)) {
        _s.grid = undefined;
        return;
    }
    if (_s.grid != _grid || _s.oid == undefined || array_length(_s.oid) != _grid.node_len) {
        mt_sync_baseline(_grid);
        return;
    }
    var _started = get_timer();
    var _w = _grid.dims.x;
    var _h = _grid.dims.y;

    if (_rt.frame % MT_SYNC_NEAR_INTERVAL == 0) {
        var _cx = floor(obj_ari.x / OBJECT_CELL_SIZE);
        var _cy = floor(obj_ari.y / OBJECT_CELL_SIZE);
        var _x0 = max(0, _cx - MT_SYNC_NEAR_RADIUS);
        var _y0 = max(0, _cy - MT_SYNC_NEAR_RADIUS);
        var _x1 = min(_w - 1, _cx + MT_SYNC_NEAR_RADIUS);
        var _y1 = min(_h - 1, _cy + MT_SYNC_NEAR_RADIUS);
        for (var _yy = _y0; _yy <= _y1; _yy++) {
            var _row = _yy * _w;
            for (var _xx = _x0; _xx <= _x1; _xx++) {
                mt_sync_scan_cell(_s, _grid, _row + _xx, _xx, _yy);
            }
        }
        if (_rt.frame % (MT_SYNC_NEAR_INTERVAL * MT_SYNC_SIG_INTERVAL) == 0) {
            mt_sync_scan_signatures(_s, _grid, _cx, _cy);
        }
    } else {
        var _n = _grid.node_len;
        var _count = min(MT_SYNC_SWEEP_CELLS, _n);
        var _ni = _s.cursor;
        for (var _k = 0; _k < _count; _k++) {
            if (_ni >= _n) { _ni = 0; }
            mt_sync_scan_cell(_s, _grid, _ni, _ni % _w, _ni div _w);
            _ni += 1;
        }
        _s.cursor = _ni;
    }

    while (array_length(_s.terrain_out) > 0) {
        var _take = min(MT_SYNC_TERRAIN_BATCH, array_length(_s.terrain_out));
        var _cells = [];
        array_copy(_cells, 0, _s.terrain_out, 0, _take);
        array_delete(_s.terrain_out, 0, _take);
        mt_send(MT_TO_ALL, { t: "wt", g: mt_sync_grid_ref(_grid), c: _cells });
        _s.sent += 1;
    }
    _s.scan_us = _s.scan_us * 0.95 + (get_timer() - _started) * 0.05;
}

// ---------------------------------------------------------------------------
// Live changes: applying what others did
// ---------------------------------------------------------------------------

function mt_sync_apply_object(_d) {
    var _grid = mt_sync_find_grid(_d[$ "g"]);
    var _obj = _d[$ "o"];
    if (_grid == undefined || !is_struct(_obj) || !is_numeric(_d[$ "x"]) || !is_numeric(_d[$ "y"])) { return; }
    if (_grid.try_node_index_for_cell(_d.x, _d.y) == undefined) { return; }
    var _oid = try_string_to_object_id(_obj[$ "object_id"]);
    if (_oid == undefined || !mt_sync_object_synced(_oid)) { return; }
    // An older version of the same object makes way for the incoming one.
    var _existing = mt_sync_find_by_root(_grid, _d.x, _d.y);
    if (_existing != undefined) { erase_object_node(_grid, _existing); }
    _grid.load_objects([_obj], mt_sync_inventories(_d[$ "iv"]));

    var _s = mt_sync_state();
    if (_s.grid == _grid) {
        var _key = string(_d.x) + ":" + string(_d.y);
        mt_sync_rebaseline_rect(_grid, _d.x - 1, _d.y - 1, _d.x + 12, _d.y + 12);
        var _ni = mt_sync_find_by_root(_grid, _d.x, _d.y);
        if (_ni != undefined) {
            _s.live[$ _key] = _grid.node_object_id[_ni];
            try { _s.sigs[$ _key] = json_stringify(mt_sync_object_data(_grid.node_parent[_ni])); } catch (_e) {}
        } else {
            struct_remove(_s.live, _key);
        }
    }
}

function mt_sync_apply_delete(_d) {
    var _grid = mt_sync_find_grid(_d[$ "g"]);
    if (_grid == undefined || !is_numeric(_d[$ "x"]) || !is_numeric(_d[$ "y"])) { return; }
    var _ni = mt_sync_find_by_root(_grid, _d.x, _d.y);
    if (_ni == undefined || !mt_sync_object_synced(_grid.node_object_id[_ni])) { return; }
    erase_object_node(_grid, _ni);
    var _s = mt_sync_state();
    if (_s.grid == _grid) {
        var _key = string(_d.x) + ":" + string(_d.y);
        mt_sync_rebaseline_rect(_grid, _d.x - 1, _d.y - 1, _d.x + 12, _d.y + 12);
        struct_remove(_s.live, _key);
        struct_remove(_s.sigs, _key);
    }
}

function mt_sync_apply_terrain(_d) {
    var _grid = mt_sync_find_grid(_d[$ "g"]);
    var _cells = _d[$ "c"];
    if (_grid == undefined || !is_array(_cells)) { return; }
    var _current = _grid == GRID;
    var _w = _grid.dims.x;
    for (var _i = 0; _i < array_length(_cells); _i++) {
        var _c = _cells[_i];
        if (!is_array(_c) || array_length(_c) < 4) { continue; }
        var _x = _c[0];
        var _y = _c[1];
        if (!is_numeric(_x) || !is_numeric(_y) || _x < 0 || _y < 0 || _x > _grid.dims.x - 2 || _y > _grid.dims.y - 2) { continue; }
        var _ni = _y * _w + _x;
        var _gk = _c[2];
        if (is_numeric(_gk) && _gk >= 0 && _grid.node_terrain_ground_kind[_ni] != _gk) {
            _grid.write_ground(_x, _y, _gk);
        }
        var _wet = _c[3] == 1;
        if (_grid.node_terrain_is_watered[_ni] != _wet) {
            _grid.node_terrain_is_watered[_ni] = _wet;
            _grid.node_terrain_is_watered[_ni + 1] = _wet;
            _grid.node_terrain_is_watered[_ni + _w] = _wet;
            _grid.node_terrain_is_watered[_ni + _w + 1] = _wet;
            if (_current && _grid.is_setup) { _grid.update_tilemap_for_node(_x, _y); }
        }
        mt_sync_rebaseline_rect(_grid, _x, _y, _x + 1, _y + 1);
    }
}

function mt_sync_on_message(_peer, _t, _d) {
    var _rt = __mt_rt();
    var _s = mt_sync_state();
    if (!mt_sync_enabled()) { return; }
    switch (_t) {
        case "wreq":
            if (mt_is_host()) { array_push(_s.send_to, _peer.id); }
            break;
        case "wo":
        case "wd":
        case "wt":
            // A guest that has not loaded the host's world yet has nothing
            // these changes could apply to.
            if (mt_is_guest() && !_s.adopted) { break; }
            if (GRIDS == undefined) { break; }
            _s.received += 1;
            try {
                if (_t == "wo") { mt_sync_apply_object(_d); }
                else if (_t == "wd") { mt_sync_apply_delete(_d); }
                else { mt_sync_apply_terrain(_d); }
            } catch (_e) {
                mmapi_warn_rate_limited("mt_sync_apply", MT_MOD, "could not apply a world change (" + _t + "): " + string(_e));
            }
            break;
    }
}

// ---------------------------------------------------------------------------
// Per-frame work
// ---------------------------------------------------------------------------

function mt_sync_tick() {
    var _rt = __mt_rt();
    if (!mt_sync_enabled()) { return; }
    var _s = mt_sync_state();

    if (mt_is_host()) {
        if (_s.send_all && array_length(_rt.peer_ids) > 0) {
            _s.send_all = false;
            _s.send_to = [];
            mt_sync_send_snapshot(MT_TO_ALL);
        } else if (array_length(_s.send_to) > 0) {
            var _to = _s.send_to[0];
            array_delete(_s.send_to, 0, 1);
            if (mt_peer(_to) != undefined) { mt_sync_send_snapshot(_to); }
        }
        _s.send_all = false;
        mt_sync_scan();
        return;
    }

    if (_s.want_snapshot && _rt.frame - _s.requested_frame > 600) {
        _s.requested_frame = _rt.frame;
        mt_send(MT_TO_HOST, { t: "wreq" });
    }
    mt_sync_try_apply_pending();
    if (_s.adopted) { mt_sync_scan(); }
}

// ---------------------------------------------------------------------------
// Test hooks (MtDev.gml)
// ---------------------------------------------------------------------------

function mt_sync_dev_command(_cmd) {
    var _cx = floor(obj_ari.x / OBJECT_CELL_SIZE);
    var _cy = floor(obj_ari.y / OBJECT_CELL_SIZE);
    var _x = (_cmd[$ "x"] ?? (_cx + 2));
    var _y = (_cmd[$ "y"] ?? (_cy + 2));
    switch (_cmd[$ "cmd"]) {
        case "till":
            GRID.write_ground(_x, _y, GroundKind.Soil);
            break;
        case "water":
            var _ni = GRID.node_index_for_cell((_x div 2) * 2, (_y div 2) * 2);
            var _w = GRID.dims.x;
            GRID.node_terrain_is_watered[_ni] = true;
            GRID.node_terrain_is_watered[_ni + 1] = true;
            GRID.node_terrain_is_watered[_ni + _w] = true;
            GRID.node_terrain_is_watered[_ni + _w + 1] = true;
            GRID.update_tilemap_for_node((_x div 2) * 2, (_y div 2) * 2);
            break;
        case "put":
            GRID.write_node(_x, _y, string_to_object_id(_cmd.object));
            break;
        case "erase":
            erase_object_node(GRID, GRID.node_index_for_cell(_x, _y));
            break;
        case "hit":
            var _node = GRID.node_parent[GRID.node_index_for_cell(_x, _y)];
            _node.hitpoints -= 1;
            break;
        case "sig":
            var _sni = GRID.node_index_for_cell(_x, _y);
            var _ss = mt_sync_state();
            mt_dev_note("sig known=" + string(_ss.sigs[$ (string(_x) + ":" + string(_y))] != undefined)
                + " frame=" + string(_ss.sig_frame[$ (string(_x) + ":" + string(_y))])
                + " tracking=" + string(_ss.grid == GRID));
            mt_dev_note("sig " + string_copy(json_stringify(mt_sync_object_data(GRID.node_parent[_sni])), 1, 300));
            break;
        case "newday":
            new_day();
            break;
        case "cell":
            var _cni = GRID.node_index_for_cell(_x, _y);
            var _oid = GRID.node_object_id[_cni];
            var _hp = undefined;
            var _tl = "";
            if (_oid != undefined) {
                _hp = GRID.node_parent[_cni][$ "hitpoints"];
                _tl = " root=" + string(GRID.node_parent[_cni].top_left_x) + "," + string(GRID.node_parent[_cni].top_left_y);
            }
            mt_dev_note("cell " + string(_x) + "," + string(_y) + " obj=" + (_oid == undefined ? "none" : object_id_to_string(_oid))
                + " hp=" + string(_hp) + _tl
                + " gk=" + string(GRID.node_terrain_ground_kind[_cni]) + " wet=" + string(GRID.node_terrain_is_watered[_cni]));
            break;
        case "find":
            // Report the first few objects in the current grid.
            var _found = 0;
            for (var _fi = 0; _fi < GRID.node_len && _found < 12; _fi++) {
                var _fo = GRID.node_object_id[_fi];
                if (_fo == undefined || GRID.node_parent[_fi].top_left_x != _fi % GRID.dims.x || GRID.node_parent[_fi].top_left_y != _fi div GRID.dims.x) { continue; }
                if (_cmd[$ "category"] != undefined && object_id_to_object_category(_fo) != _cmd.category) { continue; }
                mt_dev_note("obj " + object_id_to_string(_fo) + " @" + string(_fi % GRID.dims.x) + "," + string(_fi div GRID.dims.x)
                    + " cat=" + string(object_id_to_object_category(_fo)));
                _found += 1;
            }
            break;
    }
}

function mt_sync_dev_state() {
    var _s = mt_sync_state();
    var _objects = 0;
    if (GRID != undefined) {
        var _n = GRID.node_len;
        var _w = GRID.dims.x;
        for (var _i = 0; _i < _n; _i++) {
            if (GRID.node_object_id[_i] != undefined && GRID.node_parent[_i].top_left_x == _i % _w && GRID.node_parent[_i].top_left_y == _i div _w) { _objects += 1; }
        }
    }
    // Everything within reach of the player, as comparable text: two games
    // that agree about the world produce the same list.
    var _near = [];
    if (GRID != undefined && instance_exists(obj_ari)) {
        var _cx = floor(obj_ari.x / OBJECT_CELL_SIZE);
        var _cy = floor(obj_ari.y / OBJECT_CELL_SIZE);
        var _seen = {};
        var _gw = GRID.dims.x;
        for (var _yy = max(0, _cy - 14); _yy <= min(GRID.dims.y - 1, _cy + 14); _yy++) {
            for (var _xx = max(0, _cx - 14); _xx <= min(_gw - 1, _cx + 14); _xx++) {
                var _ni = _yy * _gw + _xx;
                if ((_xx & 1) == 0 && (_yy & 1) == 0 && (GRID.node_terrain_ground_kind[_ni] == GroundKind.Soil)) {
                    array_push(_near, "soil@" + string(_xx) + "," + string(_yy) + (GRID.node_terrain_is_watered[_ni] ? "#wet" : "#dry"));
                }
                if (GRID.node_object_id[_ni] == undefined) { continue; }
                var _p = GRID.node_parent[_ni];
                var _key = string(_p.top_left_x) + "," + string(_p.top_left_y);
                if (_seen[$ _key] != undefined) { continue; }
                _seen[$ _key] = true;
                array_push(_near, object_id_to_string(_p.object_id) + "@" + _key + "#" + string(_p[$ "hitpoints"]) + "/" + string(_p[$ "stage"]));
            }
        }
        array_sort(_near, true);
    }
    return {
        near: _near,
        adopted: _s.adopted,
        applied: _s.applied,
        want: _s.want_snapshot,
        sent: _s.sent,
        received: _s.received,
        scan_us: round(_s.scan_us),
        objects: _objects,
        dims: GRID == undefined ? [0, 0] : [GRID.dims.x, GRID.dims.y],
    };
}

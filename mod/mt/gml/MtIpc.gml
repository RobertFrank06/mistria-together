// Mistria Together - MtIpc.gml: the file bridge to the companion program.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The engine's GML has no sockets, so the game and the companion exchange
// small JSON files inside <save dir>/mod_data/mistria_together/ipc/:
//
//   game.json                    game heartbeat + identity      (game writes)
//   link.json                    companion heartbeat + status   (companion writes)
//   g_<sid>_<epoch>_<n>.json     message batch, game -> companion
//   l_<epoch>_<sid>_<n>.json     message batch, companion -> game
//
// Every file is written under a temporary name and renamed into place, so a
// reader never sees a half-written file, and batches are numbered, so nothing
// is ever overwritten, lost or reordered. `sid` identifies this game process
// and `epoch` the companion process; whenever either restarts the pair is new
// and both counters restart at zero.

#macro MT_IPC_MAX_READS_PER_FRAME 8
#macro MT_IPC_LINK_TIMEOUT 150
#macro MT_IPC_GAME_INTERVAL 30
#macro MT_IPC_LINK_INTERVAL 10

function mt_ipc_init() {
    var _rt = __mt_rt();
    var _dir = mmapi_config_dir(MT_MOD) + "/ipc";
    var _instance = environment_get_variable("MISTRIA_TOGETHER_INSTANCE");
    if (is_string(_instance) && _instance != "") { _dir += "_" + _instance; }
    try {
        if (!directory_exists(_dir)) { directory_create(_dir); }
    } catch (_e) {
        mt_warn("could not create ipc dir " + _dir + ": " + string(_e));
    }
    _rt.dir = _dir;
    _rt.sid = string(irandom(899999) + 100000) + string(floor(get_timer()) % 100000);
    mt_ipc_write_game(true);
}

// Atomic write: tmp file, then rename.
function mt_ipc_write(_name, _text) {
    var _rt = __mt_rt();
    var _tmp = _rt.dir + "/game.tmp";
    try {
        save_text_file(_tmp, _text);
        file_rename(_tmp, _rt.dir + "/" + _name);
        return true;
    } catch (_e) {
        mmapi_warn_rate_limited("mt_ipc_write", MT_MOD, "ipc write failed (" + _name + "): " + string(_e));
        return false;
    }
}

function mt_ipc_write_game(_force) {
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { return; }
    if (!_force && !_rt.game_dirty && _rt.frame - _rt.game_written_frame < MT_IPC_GAME_INTERVAL) { return; }
    _rt.game_dirty = false;
    _rt.game_written_frame = _rt.frame;
    var _name = "";
    var _farm = "";
    if (_rt.in_world && instance_exists(obj_ari)) {
        _name = string(ARI.name);
        _farm = string(ARI.farm_name);
    }
    mt_ipc_write("game.json", json_stringify({
        proto: MT_PROTO,
        ver: MT_VERSION,
        sid: _rt.sid,
        hb: _rt.frame,
        ready: _rt.in_world,
        name: _name,
        farm: _farm,
    }));
}

function mt_ipc_read_link() {
    var _rt = __mt_rt();
    var _path = _rt.dir + "/link.json";
    var _link = undefined;
    if (file_exists(_path)) { _link = try_read_json_file(_path, undefined, false); }
    if (is_struct(_link) && is_string(_link[$ "epoch"])) {
        if (_link[$ "hb"] != _rt.link_hb || _link.epoch != _rt.epoch) {
            _rt.link_hb = _link[$ "hb"];
            _rt.link_hb_frame = _rt.frame;
        }
        if (_rt.frame - _rt.link_hb_frame <= MT_IPC_LINK_TIMEOUT) {
            if (_link.epoch != _rt.epoch || !_rt.link_alive) {
                // New pairing: both message counters restart.
                _rt.epoch = _link.epoch;
                _rt.in_seq = 0;
                _rt.out_seq = 0;
                _rt.outbox = [];
                _rt.link_alive = true;
                mt_net_reset("companion (re)started");
                mt_log("paired with companion " + _rt.epoch);
            }
            var _state = _link[$ "state"];
            var _detail = _link[$ "detail"];
            _rt.link_state = is_string(_state) ? _state : "idle";
            _rt.link_detail = is_string(_detail) ? _detail : "";
            return;
        }
    }
    if (_rt.link_alive && _rt.frame - _rt.link_hb_frame > MT_IPC_LINK_TIMEOUT) {
        _rt.link_alive = false;
        _rt.link_state = "off";
        _rt.link_detail = "";
        _rt.outbox = [];
        mt_net_reset("companion stopped");
        mt_log("companion went away");
    }
}

// Called once per frame: heartbeat out, status in, then drain inbound batches.
function mt_ipc_pump() {
    var _rt = __mt_rt();
    if (_rt.dir == undefined) { return; }
    mt_ipc_write_game(false);
    if (_rt.frame % MT_IPC_LINK_INTERVAL == 0) { mt_ipc_read_link(); }
    if (!_rt.link_alive) { return; }

    var _prefix = _rt.dir + "/l_" + _rt.epoch + "_" + _rt.sid + "_";
    for (var _i = 0; _i < MT_IPC_MAX_READS_PER_FRAME; _i++) {
        var _path = _prefix + string(_rt.in_seq) + ".json";
        if (!file_exists(_path)) { break; }
        var _batch = try_read_json_file(_path, undefined, false);
        try { file_delete(_path); } catch (_e) {}
        _rt.in_seq += 1;
        if (!is_struct(_batch) || !is_array(_batch[$ "m"])) {
            mt_warn("skipped unreadable batch " + _path);
            continue;
        }
        var _msgs = _batch.m;
        var _count = array_length(_msgs);
        for (var _k = 0; _k < _count; _k++) {
            var _msg = _msgs[_k];
            try {
                mt_net_dispatch(_msg.f, _msg.d);
            } catch (_err) {
                mmapi_warn_rate_limited("mt_dispatch", MT_MOD, "message handler failed: " + string(_err));
            }
        }
    }
}

// Queue a message. `_to` is a peer id, MT_TO_ALL or MT_TO_HOST. Unreliable
// messages may be dropped or arrive out of order, and must stay small.
function mt_send(_to, _data, _unreliable = false) {
    var _rt = __mt_rt();
    if (!_rt.link_alive) { return; }
    array_push(_rt.outbox, { to: _to, u: _unreliable ? 1 : 0, d: _data });
}

// A request to the companion itself rather than to another player.
function mt_send_link(_data) {
    var _rt = __mt_rt();
    if (!_rt.link_alive) { return; }
    array_push(_rt.outbox, { to: -3, u: 0, d: _data });
}

function mt_ipc_flush() {
    var _rt = __mt_rt();
    if (array_length(_rt.outbox) == 0) { return; }
    if (!_rt.link_alive) {
        _rt.outbox = [];
        return;
    }
    var _name = "g_" + _rt.sid + "_" + _rt.epoch + "_" + string(_rt.out_seq) + ".json";
    var _text = undefined;
    try {
        _text = json_stringify({ m: _rt.outbox });
    } catch (_e) {
        mt_warn("dropping unserializable batch: " + string(_e));
    }
    _rt.outbox = [];
    if (_text == undefined) { return; }
    if (mt_ipc_write(_name, _text)) { _rt.out_seq += 1; }
}

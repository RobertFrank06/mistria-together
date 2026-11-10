// Mistria Together - MtNet.gml: the session roster and message dispatch.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Messages arrive as (from, data). `from` is a peer id, or -1 for messages the
// companion itself produced (welcome / join / leave / bye / blob / stat).
// `data.t` names the message type.

function mt_peer(_id) {
    return __mt_rt().peers[$ string(_id)];
}

function mt_peer_name(_id) {
    var _peer = mt_peer(_id);
    if (_peer == undefined) { return "Player " + string(_id); }
    return _peer.name;
}

function mt_net_add_peer(_id, _name) {
    var _rt = __mt_rt();
    if (_id == _rt.self_id) { return undefined; }
    var _key = string(_id);
    var _peer = _rt.peers[$ _key];
    if (_peer != undefined) {
        _peer.name = _name;
        return _peer;
    }
    _peer = {
        id: _id,
        name: _name,
        farm: "",
        ping: -1,
        look: undefined,        // serialized PlayerAnimationAssets
        look_key: "",
        loc: undefined,         // location key the peer is in
        state: undefined,       // slow-changing visual state (held item, tool, ...)
        state_key: "",
        inst: undefined,            // obj_mt_player instance while in our room
        buf: [],                // pose samples waiting to be played back
        last_s: -1,             // newest sample sequence seen
        last_pose_frame: 0,
    };
    _rt.peers[$ _key] = _peer;
    array_push(_rt.peer_ids, _id);
    return _peer;
}

function mt_net_remove_peer(_id) {
    var _rt = __mt_rt();
    var _key = string(_id);
    var _peer = _rt.peers[$ _key];
    if (_peer == undefined) { return; }
    mt_players_destroy_ghost(_peer);
    struct_remove(_rt.peers, _key);
    for (var _i = array_length(_rt.peer_ids) - 1; _i >= 0; _i--) {
        if (_rt.peer_ids[_i] == _id) { array_delete(_rt.peer_ids, _i, 1); }
    }
}

// Drop the whole session (companion gone, hub connection lost, back to title).
function mt_net_reset(_reason) {
    var _rt = __mt_rt();
    var _was_online = _rt.online;
    for (var _i = array_length(_rt.peer_ids) - 1; _i >= 0; _i--) {
        mt_net_remove_peer(_rt.peer_ids[_i]);
    }
    _rt.peers = {};
    _rt.peer_ids = [];
    _rt.online = false;
    _rt.self_id = -1;
    _rt.host_id = -1;
    _rt.look_sent_key = "";
    _rt.state_sent_key = "";
    _rt.pose_sent = undefined;
    mt_world_reset();
    if (_was_online) {
        mt_log("session ended: " + string(_reason));
        mt_ui_toast("Disconnected: " + string(_reason));
    }
}

function mt_net_dispatch(_from, _d) {
    if (!is_struct(_d)) { return; }
    var _t = _d[$ "t"];
    if (_from < 0) {
        mt_net_dispatch_system(_t, _d);
        return;
    }
    var _rt = __mt_rt();
    if (!_rt.online) { return; }
    var _peer = mt_peer(_from);
    if (_peer == undefined) { return; }

    switch (_t) {
        case "p":   mt_players_on_pose(_peer, _d); break;
        case "ps":  mt_players_on_state(_peer, _d); break;
        case "hi":  mt_players_on_hello(_peer, _d); break;
        case "em":  mt_players_on_emote(_peer, _d); break;
        default:    mt_world_on_message(_peer, _t, _d); break;
    }
}

function mt_net_dispatch_system(_t, _d) {
    var _rt = __mt_rt();
    switch (_t) {
        case "welcome":
            mt_net_reset("reconnected");
            _rt.online = true;
            _rt.self_id = _d.id;
            _rt.host_id = _d.host;
            var _roster = _d[$ "peers"];
            if (is_array(_roster)) {
                for (var _i = 0; _i < array_length(_roster); _i++) {
                    mt_net_add_peer(_roster[_i].id, string(_roster[_i].name));
                }
            }
            mt_log("online as player " + string(_rt.self_id) + (mt_is_host() ? " (host)" : " (guest)")
                + ", " + string(array_length(_rt.peer_ids)) + " other player(s)");
            mt_ui_toast(mt_is_host() ? "Hosting - waiting for players" : "Joined " + mt_peer_name(_rt.host_id) + "'s farm");
            mt_players_send_hello(MT_TO_ALL);
            mt_world_on_online();
            break;

        case "join":
            if (!_rt.online) { break; }
            mt_net_add_peer(_d.id, string(_d.name));
            mt_log("player " + string(_d.id) + " joined: " + string(_d.name));
            mt_ui_toast(string(_d.name) + " joined");
            mt_players_send_hello(_d.id);
            mt_world_on_peer_joined(_d.id);
            break;

        case "leave":
            if (!_rt.online) { break; }
            mt_ui_toast(mt_peer_name(_d.id) + " left");
            mt_log("player " + string(_d.id) + " left");
            mt_net_remove_peer(_d.id);
            break;

        case "bye":
            mt_net_reset(is_string(_d[$ "reason"]) ? _d.reason : "connection lost");
            break;

        case "stat":
            var _pings = _d[$ "pings"];
            if (is_array(_pings)) {
                for (var _k = 0; _k < array_length(_pings); _k++) {
                    var _peer = mt_peer(_pings[_k].id);
                    if (_peer != undefined) { _peer.ping = _pings[_k].ms; }
                }
            }
            break;

        case "blob":
            mt_world_on_blob(_d);
            break;
    }
}

// Housekeeping that has to run even when we are not in the world.
function mt_net_tick() {
    var _rt = __mt_rt();
    var _cfg = mt_config();
    // The engine pauses the whole world when the window loses focus. That is
    // fine alone, but online it would freeze the shared clock for everybody
    // (and makes testing two windows on one machine impossible).
    if (_cfg.no_focus_pause && has_flag(PAUSE_STATUS, PauseStatus.WINDOW)) {
        PAUSE_STATUS = remove_flag(PAUSE_STATUS, PauseStatus.WINDOW);
    }
}

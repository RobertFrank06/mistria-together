// Mistria Together - MtPlayers.gml: the local player's outgoing pose and the
// other players drawn in our world.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Movement is the one thing that must feel right, so it gets its own path:
//
//   * A pose is a tiny unreliable message (position, facing, animation) sent
//     20 times a second, only while something changes. A lost one is simply
//     superseded by the next; nothing ever queues up behind a resend.
//   * Each pose carries the sender's frame number. The receiver plays poses
//     back a few frames in the past and interpolates between them on that
//     timeline, so remote players glide at their real speed no matter how
//     unevenly the packets arrive. The playback clock speeds up or slows down
//     slightly to hold the configured delay instead of jumping.
//   * Everything that rarely changes (appearance, held item, tool) travels
//     separately and reliably, only when it changes.

#macro obj_mt_player object("obj_mt_player")
#macro MT_POSE_KEEPALIVE 30
#macro MT_TELEPORT_DISTANCE 56

// ---------------------------------------------------------------------------
// Local player -> network
// ---------------------------------------------------------------------------

// A string naming the place we are in. Players only see each other when their
// keys match.
function mt_location_key() {
    if (GRID == undefined) { return ""; }
    var _key = string(GRID.location_id);
    if (GRID.dyn_index != undefined) { _key += ":" + string(GRID.dyn_index); }
    if (is_dungeon_room(room())) {
        // Dungeon floors are generated per player and are not shared (yet).
        _key += ":p" + string(__mt_rt().self_id);
    }
    return _key;
}

function mt_players_look() {
    return ARI.animation_assets().serialize();
}

function mt_players_send_hello(_to) {
    var _rt = __mt_rt();
    if (!mt_in_world()) { return; }
    var _look = mt_players_look();
    _rt.look_sent_key = json_stringify(_look);
    mt_send(_to, {
        t: "hi",
        name: string(ARI.name),
        farm: string(ARI.farm_name),
        ver: MT_VERSION,
        look: _look,
    });
    // A newcomer also needs our current held item / tool, and a fresh pose.
    _rt.state_sent_key = "";
    _rt.pose_sent = undefined;
}

function mt_players_first_modifier(_par) {
    var _slots = _par.slots;
    var _n = array_length(_slots);
    for (var _i = 0; _i < _n; _i++) {
        var _name = _slots[_i].modifier.animation_name;
        if (_name != undefined) { return _name; }
    }
    return -1;
}

// Slow-changing visual state: attachment (tool in hand), held item, tool glow.
function mt_players_local_state() {
    var _par = obj_ari.par;
    var _state = { t: "ps", att: -1, held: 0, te: _par.tool_effect, rte: _par.render_tool_effect ? 1 : 0 };
    if (_par.attachment != undefined) { _state.att = _par.attachment.name; }
    var _held = _par.held_sprite;
    if (_held != undefined && _par.held_animal_render_callback == undefined) {
        _state.held = {
            s: asset_to_string(_held.sprite_index),
            i: _held.image_index,
            xo: _held.x_offset,
            fxo: _held.flipped_x_offset,
            yo: _held.y_offset,
            fl: _held.flips ? 1 : 0,
        };
    }
    return _state;
}

function mt_players_tick() {
    var _rt = __mt_rt();
    var _cfg = mt_config();
    var _loc = mt_location_key();

    // Keep one ghost instance per peer that shares our location. Room changes
    // destroy instances behind our back, so this is re-checked every frame.
    var _ids = _rt.peer_ids;
    for (var _i = array_length(_ids) - 1; _i >= 0; _i--) {
        var _peer = _rt.peers[$ string(_ids[_i])];
        if (_peer == undefined) { continue; }
        var _has = _peer.inst != undefined && instance_exists(_peer.inst);
        var _want = _peer.loc == _loc && array_length(_peer.buf) > 0;
        if (_want && !_has) {
            mt_players_create_ghost(_peer);
        } else if (!_want && _has) {
            mt_players_destroy_ghost(_peer);
        }
    }

    if (_rt.frame % 60 == 0) {
        var _look_key = json_stringify(mt_players_look());
        if (_look_key != _rt.look_sent_key) { mt_players_send_hello(MT_TO_ALL); }
    }

    if (_rt.frame % _cfg.send_interval != 0) { return; }

    var _state = mt_players_local_state();
    var _state_key = json_stringify(_state);
    if (_state_key != _rt.state_sent_key) {
        _rt.state_sent_key = _state_key;
        mt_send(MT_TO_ALL, _state);
    }

    var _ari = obj_ari;
    var _par = _ari.par;
    var _anim = _par.base_animation();
    if (_anim == undefined) { _anim = -1; }
    var _pose = {
        t: "p",
        s: _rt.frame,
        l: _loc,
        x: round(_ari.x * 100) / 100,
        y: round(_ari.y * 100) / 100,
        z: round(_ari.z * 100) / 100,
        c: _ari.cardinal,
        a: _anim,
        f: _par.base_current_frame_index(),
        m: mt_players_first_modifier(_par),
    };
    var _last = _rt.pose_sent;
    var _since = _rt.frame - _rt.pose_sent_frame;
    if (_last != undefined && _since < MT_POSE_KEEPALIVE
        && _last.x == _pose.x && _last.y == _pose.y && _last.z == _pose.z
        && _last.c == _pose.c && _last.a == _pose.a && _last.m == _pose.m && _last.l == _pose.l) {
        return;
    }
    // "h" tells receivers we stood still since the previous pose, so they hold
    // the old position until just before this one instead of sliding slowly.
    if (_last != undefined && _since > _cfg.send_interval * 2) { _pose.h = 1; }
    _rt.pose_sent = _pose;
    _rt.pose_sent_frame = _rt.frame;
    mt_send(MT_TO_ALL, _pose, true);
}

// ---------------------------------------------------------------------------
// Network -> remote players
// ---------------------------------------------------------------------------

function mt_players_on_hello(_peer, _d) {
    if (is_string(_d[$ "name"])) { _peer.name = _d.name; }
    if (is_string(_d[$ "farm"])) { _peer.farm = _d.farm; }
    var _look = _d[$ "look"];
    if (is_struct(_look) && is_array(_look[$ "assets"])) {
        _peer.look = _look;
        _peer.look_key = json_stringify(_look);
        if (_peer.inst != undefined && instance_exists(_peer.inst)) { mt_ghost_apply_look(_peer.inst, _peer); }
    }
}

function mt_players_on_state(_peer, _d) {
    _peer.state = _d;
    _peer.state_key = json_stringify(_d);
    if (_peer.inst != undefined && instance_exists(_peer.inst)) { mt_ghost_apply_state(_peer.inst, _peer); }
}

function mt_players_on_pose(_peer, _d) {
    var _s = _d[$ "s"];
    if (!is_numeric(_s) || !is_numeric(_d[$ "x"]) || !is_numeric(_d[$ "y"])) { return; }
    if (_s <= _peer.last_s && _peer.last_s - _s < 600) { return; }   // stale / duplicate
    var _loc = _d[$ "l"];
    var _buf = _peer.buf;
    var _n = array_length(_buf);
    if (_loc != _peer.loc || _s < _peer.last_s) {
        // Changed room (or the sender restarted): start a fresh timeline.
        _peer.loc = _loc;
        _buf = [];
        _peer.buf = _buf;
        _n = 0;
        if (_peer.inst != undefined && instance_exists(_peer.inst)) { _peer.inst.mt_play = -1; }
    }
    if (_n > 0 && _d[$ "h"] == 1) {
        var _prev = _buf[_n - 1];
        if (_s - 1 > _prev.s) {
            array_push(_buf, { s: _s - 1, x: _prev.x, y: _prev.y, z: _prev.z, c: _prev.c, a: _prev.a, f: _prev.f, m: _prev.m });
        }
    }
    array_push(_buf, {
        s: _s, x: _d.x, y: _d.y,
        z: is_numeric(_d[$ "z"]) ? _d.z : 0,
        c: _d[$ "c"], a: _d[$ "a"], f: _d[$ "f"], m: _d[$ "m"],
    });
    while (array_length(_buf) > 120) { array_delete(_buf, 0, 1); }
    _peer.last_s = _s;
    _peer.last_pose_frame = __mt_rt().frame;
}

function mt_players_create_ghost(_peer) {
    var _first = _peer.buf[0];
    var _inst = instance_create_depth(_first.x, _first.y, get_instance_depth(_first.y), obj_mt_player);
    _inst.mt_peer_id = _peer.id;
    _peer.inst = _inst;
    mt_ghost_apply_look(_inst, _peer);
    mt_ghost_apply_state(_inst, _peer);
    return _inst;
}

function mt_players_destroy_ghost(_peer) {
    if (_peer.inst != undefined && instance_exists(_peer.inst)) { instance_destroy(_peer.inst); }
    _peer.inst = undefined;
}

// ---------------------------------------------------------------------------
// The ghost: another player's character in our room
// ---------------------------------------------------------------------------

function mt_ghost_apply_look(_g, _peer) {
    if (_peer.look == undefined || _g.mt_look_key == _peer.look_key) { return; }
    try {
        var _par = _g.par;
        for (var _i = 0; _i < array_length(_g.mt_assets); _i++) {
            try { _par.remove_asset(_g.mt_assets[_i]); } catch (_e) {}
        }
        var _assets = [];
        var _names = [];
        var _src = _peer.look.assets;
        for (var _k = 0; _k < array_length(_src); _k++) {
            var _asset = _src[_k];
            // Skip cosmetics this install does not know (e.g. from another mod).
            if (!is_struct(_asset) || PLAYER_ANIMATION_DATABASE.player_assets.get(_asset[$ "name"]) == undefined) { continue; }
            array_push(_assets, { name: _asset.name, lut_index: _asset.lut_index });
            array_push(_names, _asset.name);
        }
        var _paa = player_animation_assets_deserialize({
            assets: _assets,
            skin_tone: _peer.look.skin_tone,
            eyes: _peer.look.eyes,
        });
        _paa.apply_to_par(_par);
        _names = [];
        for (var _m = 0; _m < _paa.assets.count(); _m++) { array_push(_names, _paa.assets.get(_m).name); }
        _g.mt_assets = _names;
        _g.mt_look_key = _peer.look_key;
    } catch (_err) {
        mmapi_warn_rate_limited("mt_look", MT_MOD, "could not apply " + _peer.name + "'s appearance: " + string(_err));
    }
}

function mt_ghost_apply_state(_g, _peer) {
    var _st = _peer.state;
    if (_st == undefined || _g.mt_state_key == _peer.state_key) { return; }
    _g.mt_state_key = _peer.state_key;
    var _par = _g.par;
    try {
        if (_st[$ "att"] == undefined || _st.att == -1) {
            _par.remove_attachment();
        } else {
            _par.set_attachment(_st.att);
        }
    } catch (_e) { _par.remove_attachment(); }
    try {
        var _held = _st[$ "held"];
        if (is_struct(_held)) {
            _par.set_held_sprite(string_to_asset(_held.s), _held.i, _held.xo, _held.yo, _held.fxo, _held.fl == 1);
        } else {
            _par.remove_held_sprite();
        }
    } catch (_e2) { _par.remove_held_sprite(); }
    if (is_numeric(_st[$ "te"])) { _par.tool_effect = _st.te; }
    _par.render_tool_effect = _st[$ "rte"] != 0;
}

function mt_ghost_set_pose(_g, _sample) {
    var _par = _g.par;
    var _c = _sample.c;
    if (is_numeric(_c) && _c != _g.cardinal && _c >= 0 && _c < Cardinal.LEN) {
        _g.cardinal = _c;
        _par.set_cardinal(_c);
    }
    var _a = _sample.a;
    if (is_numeric(_a) && _a >= 0) {
        if (_a != _g.mt_anim) {
            _g.mt_anim = _a;
            _par.set_animation(_a);
            if (is_numeric(_sample.f) && _sample.f > 0) { _par.base_to_frame(_a, _sample.f); }
        } else if (is_numeric(_sample.f) && _sample != _g.mt_sample) {
            // Same animation: nudge the frame only when we drifted visibly.
            if (abs(_par.base_current_frame_index() - _sample.f) > 1) { _par.base_to_frame(_a, _sample.f); }
        }
    }
    var _m = _sample.m;
    if (_m != _g.mt_modifier) {
        _g.mt_modifier = _m;
        if (!is_numeric(_m) || _m < 0) {
            _par.unset_all_modifiers();
        } else {
            _par.unset_all_modifiers();
            _par.set_animation(_m);
        }
    }
    _g.mt_sample = _sample;
}

function mt_ghost_step(_g) {
    var _rt = __mt_rt();
    var _peer = mt_peer(_g.mt_peer_id);
    if (_peer == undefined || !_rt.online ) {
        instance_destroy(_g);
        return;
    }
    var _buf = _peer.buf;
    var _n = array_length(_buf);
    if (_n == 0) { return; }

    var _delay = mt_config().smoothing_frames;
    var _latest = _buf[_n - 1].s;
    if (_g.mt_play < 0 || _latest - _g.mt_play > 90 || _g.mt_play - _latest > 30) {
        _g.mt_play = _latest - _delay;
    } else {
        // Hold `_delay` frames behind the newest pose by gently bending time.
        var _lag = _latest - _g.mt_play;
        _g.mt_play += 1 + clamp((_lag - _delay) * 0.04, -0.3, 0.6);
    }
    var _play = _g.mt_play;

    while (_n >= 2 && _buf[1].s <= _play) {
        array_delete(_buf, 0, 1);
        _n -= 1;
    }
    var _a = _buf[0];
    var _nx = _a.x;
    var _ny = _a.y;
    var _nz = _a.z;
    var _pose = _a;
    if (_n >= 2 && _play > _a.s) {
        var _b = _buf[1];
        var _t = (_play - _a.s) / (_b.s - _a.s);
        if (abs(_b.x - _a.x) > MT_TELEPORT_DISTANCE || abs(_b.y - _a.y) > MT_TELEPORT_DISTANCE) {
            _t = 1;     // a warp, not a walk: do not slide across the map
        }
        _nx = lerp(_a.x, _b.x, _t);
        _ny = lerp(_a.y, _b.y, _t);
        _nz = lerp(_a.z, _b.z, _t);
        if (_t >= 0.5) { _pose = _b; }
    }
    _g.x = _nx;
    _g.y = _ny;
    _g.z = _nz;
    _g.depth = get_instance_depth(_ny);
    if (_pose != _g.mt_sample) { mt_ghost_set_pose(_g, _pose); }
    _g.par.animate(_g.par_anim_spd);

    if (_g.shadow_caster != undefined) {
        _g.shadow_caster.x = _nx;
        _g.shadow_caster.y = _ny;
    }
}

function mt_ghost_draw(_g, _draw_x, _draw_y) {
    var _x = _draw_x ?? _g.x;
    var _y = _draw_y ?? _g.y;
    _g.par.draw(_x + _g.par_offset.x, _y + _g.par_offset.y + _g.z, _g.depth);
    if (mt_config().name_tags) {
        var _peer = mt_peer(_g.mt_peer_id);
        if (_peer != undefined) { mt_ui_draw_name_tag(_peer.name, _x, _y + _g.z - 44); }
    }
}

object_create(
    "obj_mt_player",
    undefined,
    {
        sprite_index: undefined,
        create: function() {
            self.z = 0;
            self.depth = get_instance_depth(self.y);
            self.par = new PlayerAnimationRuntime();
            self.par.cardinal = Cardinal.South;
            self.cardinal = Cardinal.South;
            self.par.set_animation(AnimationName.Idle);

            var _player_data = fiddle_get("player");
            self.par_offset = fiddle_deserialize_vec2(_player_data.par.offset);
            self.par_anim_spd = _player_data.par.anim_speed;

            self.mt_peer_id = -1;
            self.mt_play = -1;
            self.mt_sample = undefined;
            self.mt_anim = AnimationName.Idle;
            self.mt_modifier = -1;
            self.mt_look_key = "";
            self.mt_state_key = "";
            self.mt_assets = [];

            self.shadow_caster = undefined;
            try {
                self.shadow_caster = SHADOW_GRID.caster_create(self);
                self.shadow_caster.animation = spr_npc_shadow;
            } catch (_e) {
                self.shadow_caster = undefined;
            }
        },
        step: function() {
            mt_ghost_step(self);
        },
        draw: function(draw_x, draw_y, alpha) {
            mt_ghost_draw(self, draw_x, draw_y);
        },
    }
);

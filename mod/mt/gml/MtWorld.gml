// Mistria Together - MtWorld.gml: the shared clock, calendar and weather.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The host's game is the authority on time. Guests let their own clock run so
// lighting and schedules stay smooth, and are steered back whenever they drift
// from the host (for example after sitting in a menu, which pauses a clock).

#macro MT_TIME_INTERVAL 30
// Guest clock error, in game seconds, that is corrected by a jump.
#macro MT_TIME_TOLERANCE 150

function mt_world_state() {
    var _rt = __mt_rt();
    if (_rt.world == undefined) { mt_world_reset(); }
    return _rt.world;
}

function mt_world_reset() {
    var _rt = __mt_rt();
    _rt.world = {
        time_sent_frame: -100000,
        time_sent_key: "",
        host_paused: false,     // guest: the host's clock is not running
        have_time: false,       // guest: at least one time message arrived
    };
    mt_sync_reset();
}

function mt_world_on_online() {
    mt_sync_on_online();
}

function mt_world_on_peer_joined(_id) {
    var _w = mt_world_state();
    _w.time_sent_frame = -100000;    // push the time to the newcomer right away
    mt_sync_on_peer_joined(_id);
}

function mt_world_time_message() {
    return {
        t: "tm",
        cal: CALENDAR.time,
        clk: CLOCK.time,
        pz: (game_paused() || CLOCK.time_stopped) ? 1 : 0,
        w: WEATHER.weather,
        fc: WEATHER.forecast,
    };
}

function mt_world_tick() {
    var _rt = __mt_rt();
    var _w = mt_world_state();
    if (mt_is_host() && CLOCK != undefined && WEATHER != undefined) {
        if (_rt.frame - _w.time_sent_frame >= MT_TIME_INTERVAL) {
            _w.time_sent_frame = _rt.frame;
            if (array_length(_rt.peer_ids) > 0) { mt_send(MT_TO_ALL, mt_world_time_message()); }
        }
    }
    mt_sync_tick();
}

function mt_world_on_time(_peer, _d) {
    var _rt = __mt_rt();
    if (_peer.id != _rt.host_id || !mt_config().sync_world) { return; }
    if (CLOCK == undefined || CALENDAR == undefined) { return; }
    var _w = mt_world_state();
    _w.have_time = true;
    _w.host_paused = _d[$ "pz"] == 1;

    if (is_numeric(_d[$ "cal"]) && _d.cal != CALENDAR.time) {
        mt_sync_on_host_day(_d.cal);
    }
    if (is_numeric(_d[$ "clk"])) {
        var _diff = _d.clk - CLOCK.time;
        if (_w.host_paused && _diff != 0) {
            CLOCK.time = int64(_d.clk);
        } else if (_diff > 1200) {
            // Far behind (the host skipped time): let the engine move NPCs too.
            try { CLOCK.jump(_d.clk); } catch (_e) { CLOCK.time = int64(_d.clk); }
        } else if (abs(_diff) > MT_TIME_TOLERANCE) {
            CLOCK.time = int64(_d.clk);
        }
    }
    if (WEATHER != undefined) {
        try {
            if (is_array(_d[$ "fc"])) { WEATHER.forecast = _d.fc; }
            if (_d[$ "w"] != undefined && _d.w != WEATHER.weather) { WEATHER.set_weather(_d.w); }
        } catch (_e2) {
            mmapi_warn_rate_limited("mt_weather", MT_MOD, "weather sync failed: " + string(_e2));
        }
    }
}

function mt_world_on_message(_peer, _t, _d) {
    if (_t == "tm") {
        mt_world_on_time(_peer, _d);
        return;
    }
    mt_sync_on_message(_peer, _t, _d);
}

function mt_world_on_blob(_d) {
    mt_sync_on_blob(_d);
}

// clock.time_advance filter: a guest's clock stands still while the host's does.
function mt_world_filter_time_advance(_value, _ctx) {
    if (_value == undefined) { return undefined; }
    var _rt = __mt_rt();
    if (!_rt.online || _rt.self_id == _rt.host_id) { return undefined; }
    if (!mt_config().sync_world) { return undefined; }
    var _w = _rt.world;
    if (_w != undefined && _w.have_time && _w.host_paused) { return 0; }
    return undefined;
}

function mt_world_on_new_day(_ctx) {
    mt_sync_on_new_day(_ctx);
}

// game.save_guard: see MtSync.gml.
function mt_world_save_guard(_ctx) {
    return mt_sync_save_guard(_ctx);
}

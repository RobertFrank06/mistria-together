// Mistria Together - MtWorld.gml: the session clock, calendar and weather.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// There is one session time `st` (game seconds of the day). The host advances
// it every frame unless the host paused the session; guests receive it and
// extrapolate between messages. Every machine keeps its own CLOCK.time close
// to `st`, but only while its own game is not paused, so a menu, shop or
// scene freezes only that player's game and it catches up afterwards. Time
// skips (recipes, scene time jumps, oversleeping) are ignored while others
// are online: CLOCK.jump is wrapped (mt_clock_jump).

#macro MT_TIME_INTERVAL 30
// A local clock this far behind `st` (game seconds) catches up with a jump
// (which also moves townspeople); closer than that it is simply set.
#macro MT_TIME_SET_LIMIT 120
#macro MT_DAY_END hours(26)

function mt_world_state() {
    var _rt = __mt_rt();
    if (_rt.world == undefined) { mt_world_reset(); }
    return _rt.world;
}

function mt_world_reset() {
    var _rt = __mt_rt();
    var _old = _rt.world;
    // Give a guest back its own day length.
    if (_old != undefined && _old[$ "own_mpd"] != undefined) { MINUTES_PER_DAY = _old.own_mpd; }
    _rt.world = {
        time_sent_frame: -100000,
        time_sent_key: "",
        host_paused: false,     // the host paused the session (guest view)
        have_time: false,       // guest: at least one time message arrived
        st: 0,                  // session time, game seconds of the day
        st_active: false,       // host: st is being driven (a guest is online)
        st_paused: false,       // host: explicit pause
        st_night: false,        // host: a night is running (Phase 2)
        own_mpd: undefined,     // guest: its own MINUTES_PER_DAY while following the host's
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

// True while the session clock is in charge of this machine's clock.
function mt_world_clock_driven() {
    var _rt = __mt_rt();
    if (!_rt.online || !mt_config().sync_world) { return false; }
    var _w = mt_world_state();
    return mt_is_host() ? _w.st_active : _w.have_time;
}

function mt_world_paused_by_host() {
    var _w = mt_world_state();
    return mt_is_host() ? _w.st_paused : _w.host_paused;
}

function mt_world_time_message() {
    var _w = mt_world_state();
    return {
        t: "tm",
        cal: CALENDAR.time,
        clk: CLOCK.time,
        st: floor(_w.st),
        pz: _w.st_paused ? 1 : 0,
        night: _w.st_night ? 1 : 0,
        mpd: MINUTES_PER_DAY,
        w: WEATHER.weather,
        fc: WEATHER.forecast,
    };
}

// Host: pause or resume the session for everybody.
function mt_world_set_pause(_on) {
    if (!mt_is_host()) { return; }
    var _w = mt_world_state();
    _w.st_paused = _on;
    _w.time_sent_frame = -100000;
    mt_ui_toast(_on ? "Game paused" : "Game resumed");
}

// Wrap CLOCK.jump once per Clock (a new one is built every morning).
function mt_world_wrap_clock() {
    if (CLOCK == undefined || CLOCK[$ "__mt_jump"] != undefined) { return; }
    CLOCK.__mt_jump = CLOCK.jump;
    CLOCK.jump = method(CLOCK, mt_clock_jump);
}

// What the game (recipes, scenes, oversleeping) calls instead of the real jump.
function mt_clock_jump(_time) {
    if (mt_world_clock_driven() && !__mt_rt().jump_allowed) {
        mmapi_log_debug(MT_MOD, "ignored a time skip to " + string(_time) + " while playing together");
        return;
    }
    mt_clock_jump_real(_time);
}

// The game's own jump, used by the mod to catch a clock up.
function mt_clock_jump_real(_time) {
    var _rt = __mt_rt();
    _rt.jump_allowed = true;
    try {
        if (CLOCK[$ "__mt_jump"] != undefined) { CLOCK.__mt_jump(_time); } else { CLOCK.jump(_time); }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_jump", MT_MOD, "clock jump failed: " + string(_e));
    }
    _rt.jump_allowed = false;
}

// Keep the local clock near session time unless this game is paused.
function mt_world_follow() {
    var _w = mt_world_state();
    if (!mt_world_clock_driven() || game_paused() || _w.st_night) { return; }
    var _target = min(MT_DAY_END, floor(_w.st));
    var _diff = _target - CLOCK.time;
    if (_diff <= 0) { return; }
    if (_diff <= MT_TIME_SET_LIMIT) { CLOCK.time = int64(_target); }
    else { mt_clock_jump_real(_target); }
}

function mt_world_tick() {
    var _rt = __mt_rt();
    var _w = mt_world_state();
    if (CLOCK != undefined) { mt_world_wrap_clock(); }
    if (CLOCK != undefined && WEATHER != undefined) {
        if (mt_is_host()) {
            if (array_length(_rt.peer_ids) > 0) {
                if (!_w.st_active) { _w.st = CLOCK.time; _w.st_active = true; }
                if (!_w.st_paused && !_w.st_night) { _w.st = min(MT_DAY_END, _w.st + GAME_SECONDS_PER_FRAME); }
            } else {
                _w.st = CLOCK.time;
                _w.st_active = false;
                _w.st_paused = false;
            }
            var _key = string(_w.st_paused) + string(_w.st_night) + string(MINUTES_PER_DAY);
            if (_key != _w.time_sent_key) { _w.time_sent_key = _key; _w.time_sent_frame = -100000; }
            if (_rt.frame - _w.time_sent_frame >= MT_TIME_INTERVAL) {
                _w.time_sent_frame = _rt.frame;
                if (array_length(_rt.peer_ids) > 0) { mt_send(MT_TO_ALL, mt_world_time_message()); }
            }
        } else if (_w.have_time && !_w.host_paused && !_w.st_night) {
            _w.st = min(MT_DAY_END, _w.st + GAME_SECONDS_PER_FRAME);
        }
        mt_world_follow();
    }
    mt_sync_tick();
}

function mt_world_on_time(_peer, _d) {
    var _rt = __mt_rt();
    if (_peer.id != _rt.host_id || !mt_config().sync_world) { return; }
    if (CLOCK == undefined || CALENDAR == undefined) { return; }
    var _w = mt_world_state();
    _w.host_paused = _d[$ "pz"] == 1;
    _w.st_night = _d[$ "night"] == 1;

    if (is_numeric(_d[$ "mpd"]) && _d.mpd > 0 && _d.mpd != MINUTES_PER_DAY) {
        if (_w.own_mpd == undefined) { _w.own_mpd = MINUTES_PER_DAY; }
        MINUTES_PER_DAY = _d.mpd;
    }

    if (is_numeric(_d[$ "cal"]) && _d.cal != CALENDAR.time) {
        mt_sync_on_host_day(_d.cal);
    }
    var _st = is_numeric(_d[$ "st"]) ? _d.st : _d[$ "clk"];
    if (is_numeric(_st)) {
        _w.st = _st;
        if (!_w.have_time) {
            // First contact: start from the host's time, even if that is earlier.
            CLOCK.time = int64(_st);
        }
        _w.have_time = true;
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
    if (_t == "nr" || _t == "ns" || _t == "ng") {
        mt_night_on_message(_peer, _t, _d);
        return;
    }
    mt_sync_on_message(_peer, _t, _d);
}

function mt_world_on_blob(_d) {
    mt_sync_on_blob(_d);
}

// clock.time_advance filter: while the session clock drives this machine its
// own clock never self-advances (mt_world_follow moves it instead).
function mt_world_filter_time_advance(_value, _ctx) {
    if (_value == undefined) { return undefined; }
    return mt_world_clock_driven() ? 0 : undefined;
}

function mt_world_on_new_day(_ctx) {
    mt_night_on_new_day(_ctx);
    var _w = mt_world_state();
    if (mt_is_host()) { _w.st = hours(6); _w.st_night = false; _w.time_sent_frame = -100000; }
    mt_sync_on_new_day(_ctx);
}

// game.save_guard: see MtSync.gml.
function mt_world_save_guard(_ctx) {
    return mt_sync_save_guard(_ctx);
}

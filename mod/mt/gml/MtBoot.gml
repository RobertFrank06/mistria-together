// Mistria Together - co-op multiplayer for Fields of Mistria.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MtBoot.gml: mod identity, the runtime struct, config, and the per-frame tick.
//
// Every name this mod owns starts with `mt_` (functions), `MT_` (macros) or
// lives in `global.__mt` (state). The game side never opens a socket: it talks
// to the `mistria-together` companion program through small files (MtIpc.gml),
// and the companion does all of the networking.

#macro MT_MOD "mistria_together"
#macro MT_VERSION "0.2.0"
// Bumped whenever game-to-game messages change shape. Peers with a different
// value are refused by the companion before they ever reach the game.
#macro MT_PROTO 1
#macro MT_CONFIG_VERSION 2

#macro MT_TO_ALL -1
#macro MT_TO_HOST -2

function __mt_rt() {
    if (global[$ "__mt"] == undefined) {
        global.__mt = {
            registered: undefined,
            ready: false,       // first tick has run (file IO is safe)
            frame: 0,           // ticks since boot, 60 per second
            cfg: undefined,

            // --- ipc (MtIpc.gml) ---
            dir: undefined,
            sid: "",            // this game process' session id
            epoch: "",          // the companion's session id ("" = none seen)
            link_alive: false,
            link_hb: -1,
            link_hb_frame: 0,
            link_state: "off",  // companion state: off/idle/hosting/connecting/connected/error
            link_detail: "",
            in_seq: 0,
            out_seq: 0,
            outbox: [],
            game_dirty: true,
            game_written_frame: -100000,

            // --- session (MtNet.gml) ---
            online: false,      // welcomed by a hub
            self_id: -1,
            host_id: -1,
            peers: {},          // id string -> peer struct
            peer_ids: [],       // numeric ids, kept in sync with `peers`

            // --- local player (MtPlayers.gml) ---
            in_world: false,
            look_key: "",
            look_sent_key: "",
            pose_sent: undefined,
            pose_sent_frame: -100000,
            state_sent_key: "",

            // --- world (MtWorld.gml) ---
            world: undefined,

            // --- menu (MtMenu.gml) ---
            control_seq: 0,
            menu_mode: "off",
            title_boot: true,
            title_button: undefined,

            // --- ui (MtUi.gml) ---
            hud_visible: true,
            toasts: [],
        };
    }
    return global.__mt;
}

function mt_log(_msg) {
    mmapi_log_info(MT_MOD, _msg);
}

function mt_warn(_msg) {
    mmapi_log_warn(MT_MOD, _msg);
}

// Lazy, versioned config (mod_data/mistria_together/mistria_together.json).
function mt_config() {
    var _rt = __mt_rt();
    if (_rt.cfg != undefined) { return _rt.cfg; }
    var _src = mmapi_config_read_valid(MT_MOD, MT_CONFIG_VERSION);
    var _key = _src[$ "menu_key"];
    if (!is_string(_key) || mmapi_hotkey_binding_from_name(_key) == undefined) { _key = "F9"; }
    var _password = _src[$ "password"];
    var _last = _src[$ "last_address"];
    _rt.cfg = {
        // Show the player list / connection status in the top-left corner.
        show_hud: mmapi_config_bool(_src, "show_hud", true),
        // Draw each player's name above their head.
        name_tags: mmapi_config_bool(_src, "name_tags", true),
        // Key that opens the Multiplayer menu.
        menu_key: _key,
        // Optional session password; everyone must use the same one.
        password: is_string(_password) ? _password : "",
        // The address typed into the Join box last time.
        last_address: is_string(_last) ? _last : "",
        // How far behind real time other players are drawn, in frames. Higher
        // is smoother on bad connections, lower is more immediate.
        smoothing_frames: mmapi_config_number(_src, "smoothing_frames", 7, 2, 30),
        // Frames between position updates (3 = 20 per second).
        send_interval: mmapi_config_number(_src, "send_interval", 3, 1, 10),
        // Keep the game running when the window loses focus while online.
        no_focus_pause: mmapi_config_bool(_src, "no_focus_pause", true),
        // As a guest, adopt the host's farm, time and weather.
        sync_world: mmapi_config_bool(_src, "sync_world", true),
    };
    mmapi_config_write(MT_MOD, MT_CONFIG_VERSION, _rt.cfg);
    return _rt.cfg;
}

function mt_is_host() {
    var _rt = __mt_rt();
    return _rt.online && _rt.self_id == _rt.host_id;
}

function mt_is_guest() {
    var _rt = __mt_rt();
    return _rt.online && _rt.self_id != _rt.host_id;
}

// True while a save is loaded and the player exists in a room.
function mt_in_world() {
    return instance_exists(obj_ari) && GRID != undefined && ARI != undefined;
}

// The per-frame tick, queued with mmapi_register. Runs from the Game object's
// begin_step, so it only runs while a save is loaded (never on the title).
function mt_tick() {
    var _rt = __mt_rt();
    _rt.frame += 1;
    if (!_rt.ready) {
        _rt.ready = true;
        mt_config();
        if (_rt.dir == undefined) { mt_ipc_init(); }
        mt_menu_free_title_button();
        mt_ui_init();
        mt_log("Mistria Together " + MT_VERSION + " ready, ipc dir " + string(_rt.dir));
    }

    var _in_world = mt_in_world();
    if (_in_world != _rt.in_world) {
        _rt.in_world = _in_world;
        _rt.game_dirty = true;
    }

    mt_ipc_pump();

    if (_rt.online) {
        if (_in_world) {
            mt_players_tick();
            mt_world_tick();
        }
        mt_net_tick();
    }

    mt_ipc_flush();
    mt_dev_tick();
}

// Back on the title screen: the session is over.
function mt_on_title_entered(_ctx) {
    var _rt = __mt_rt();
    if (_rt.ready) {
        _rt.in_world = false;
        _rt.ready = false;
        mt_net_reset("left the game");
        mt_ipc_write_game(true);
    }
    mt_menu_on_title(_ctx);
    mt_dev_on_title(_ctx);
}

function mt_register() {
    var _rt = __mt_rt();
    if (_rt.registered != undefined) { return; }
    _rt.registered = true;

    mmapi_register(mt_tick);
    mmapi_on("game.title_entered", mt_on_title_entered);
    mmapi_on("ui.draw_gui", mt_ui_draw_gui);
    mmapi_on("game.new_day", mt_world_on_new_day);
    mmapi_filter("clock.time_advance", mt_world_filter_time_advance);
    mmapi_guard("game.save_guard", mt_world_save_guard);
}

mmapi_mod_declare(MT_MOD, MT_VERSION);
mt_register();

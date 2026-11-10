// Mistria Together - MtUi.gml: status HUD, toasts and name tags.
// SPDX-License-Identifier: GPL-3.0-or-later

function mt_ui_init() {
    var _rt = __mt_rt();
    _rt.hud_visible = mt_config().show_hud;
    if (_rt[$ "hotkey_registered"] == true) { return; }
    _rt.hotkey_registered = true;
    var _binding = mmapi_hotkey_binding_from_name(mt_config().menu_key);
    if (_binding != undefined) { mmapi_hotkey_register_binding(_binding, mt_ui_on_menu_key); }
}

function mt_ui_on_menu_key() {
    // Not on top of another menu, cutscene or popup.
    if (!mt_in_world() || game_paused()) { return; }
    mt_menu_open();
}

// A toast in the game's own notification stack.
function mt_ui_toast(_text) {
    try {
        if (instance_exists(obj_ari)) { create_notification(ANCHOR.wrap_for_local(string(_text))); }
    } catch (_e) {}
}

// The game's fonts are palette-indexed: text has to be drawn through a colour
// lookup table or it comes out as raw red indices.
function mt_ui_text_begin(_lut_index) {
    draw_set_font(ANCHOR.get_text_font());
    var _uvs = sprite_get_uvs(COMMON_LUT, 0);
    shader_set_texture("u_LutTexture", COMMON_LUT, 0, "u_LutTexelSize");
    gpu_set_draw_kind(DrawKind.AnchorText, _uvs[0], _uvs[1], _lut_index);
}

function mt_ui_text_end() {
    gpu_reset_draw_kind();
}

// Drawn from a ghost's draw event, so coordinates are world pixels.
function mt_ui_draw_name_tag(_name, _x, _y) {
    mt_ui_text_begin(CommonLutIndex.WhitePureBlack);
    var _w = string_width(_name);
    draw_text_with_color(floor(_x - _w * 0.5), floor(_y), _name, 1.0, 1.0, c_white, 1.0);
    mt_ui_text_end();
}

function mt_ui_status_line() {
    var _rt = __mt_rt();
    var _key = mt_config().menu_key;
    if (_rt.online) {
        return mt_is_host() ? "Hosting" : "Playing together";
    }
    switch (_rt.link_state) {
        case "connecting": return "Connecting...";
        case "error":      return _rt.link_detail;
        case "hosting":    return "Starting to host...";
        default:           return "Multiplayer: " + _key;
    }
}

// ui.draw_gui event: ctx is the display's asset_resize() value.
function mt_ui_draw_gui(_scale) {
    var _rt = __mt_rt();
    if (!_rt.ready || !_rt.hud_visible || !_rt.in_world) { return; }
    if (!_rt.link_alive && !_rt.online) { return; }   // stay out of the way in single player
    // The reminder of the menu key fades out of the way after a while.
    if (!_rt.online && _rt.link_state == "idle" && _rt.frame > 60 * 20) { return; }
    try {
        var _s = is_numeric(_scale) ? _scale : 1;
        var _lines = [mt_ui_status_line()];
        if (_rt.online) {
            var _ids = _rt.peer_ids;
            for (var _i = 0; _i < array_length(_ids); _i++) {
                var _peer = _rt.peers[$ string(_ids[_i])];
                if (_peer == undefined) { continue; }
                var _line = (_peer.id == _rt.host_id ? "* " : "  ") + _peer.name;
                if (_peer.ping >= 0) { _line += "  " + string(round(_peer.ping)) + "ms"; }
                array_push(_lines, _line);
            }
        }
        // Draw in the UI's own pixel scale, like the rest of the HUD.
        var _out = window_get_output_dimensions();
        draw_camera_override_camera(0, 0, _out[0] / _s, _out[1] / _s);
        mt_ui_text_begin(CommonLutIndex.WhitePureBlack);
        var _x = 6;
        var _y = 24;
        for (var _m = 0; _m < array_length(_lines); _m++) {
            draw_text_with_color(_x, _y + _m * 10, _lines[_m], 1.0, 1.0, c_white, 1.0);
        }
        mt_ui_text_end();
        draw_camera_override_camera(0, 0, _out[0], _out[1]);
    } catch (_e) {
        mmapi_warn_rate_limited("mt_hud", MT_MOD, "hud draw failed: " + string(_e));
    }
}

// Mistria Together - MtUi.gml: status HUD, toasts and name tags.
// SPDX-License-Identifier: GPL-3.0-or-later

function mt_ui_init() {
    var _rt = __mt_rt();
    _rt.hud_visible = mt_config().show_hud;
    var _binding = mmapi_hotkey_binding_from_name(mt_config().hud_key);
    if (_binding != undefined) { mmapi_hotkey_register_binding(_binding, mt_ui_toggle_hud); }
}

function mt_ui_toggle_hud() {
    var _rt = __mt_rt();
    _rt.hud_visible = !_rt.hud_visible;
}

// A toast in the game's own notification stack.
function mt_ui_toast(_text) {
    try {
        if (instance_exists(obj_ari)) { create_notification(ANCHOR.wrap_for_local(string(_text))); }
    } catch (_e) {}
}

// Drawn from a ghost's draw event, so coordinates are world pixels.
function mt_ui_draw_name_tag(_name, _x, _y) {
    draw_set_font(ANCHOR.get_text_font());
    var _w = string_width(_name);
    var _left = floor(_x - _w * 0.5);
    var _top = floor(_y);
    draw_sprite_ext(spr_pixel, 0, _left - 2, _top - 1, _w + 4, 9, 0, c_black, 0.45);
    draw_text_with_color(_left, _top, _name, 1.0, 1.0, c_white, 1.0);
}

function mt_ui_status_line() {
    var _rt = __mt_rt();
    if (!_rt.link_alive) { return "Together: companion not running"; }
    if (_rt.online) {
        return mt_is_host() ? "Together: hosting" : "Together: connected";
    }
    switch (_rt.link_state) {
        case "connecting": return "Together: connecting...";
        case "error":      return "Together: " + _rt.link_detail;
        case "hosting":    return "Together: starting host...";
        default:           return "Together: " + (_rt.link_detail != "" ? _rt.link_detail : "idle");
    }
}

// ui.draw_gui event: ctx is the display's asset_resize() value.
function mt_ui_draw_gui(_scale) {
    var _rt = __mt_rt();
    if (!_rt.ready || !_rt.hud_visible || !_rt.in_world) { return; }
    if (!_rt.link_alive && !_rt.online) { return; }   // stay out of the way in single player
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
        draw_set_font(ANCHOR.get_text_font());
        var _w = 0;
        for (var _k = 0; _k < array_length(_lines); _k++) { _w = max(_w, string_width(_lines[_k])); }
        var _x = 4 * _s;
        var _y = 42 * _s;
        var _line_h = 9;
        draw_sprite_ext(spr_pixel, 0, _x - 2 * _s, _y - 2 * _s, (_w + 4) * _s, (array_length(_lines) * _line_h + 3) * _s, 0, c_black, 0.45);
        for (var _m = 0; _m < array_length(_lines); _m++) {
            draw_text_with_color(_x, _y + _m * _line_h * _s, _lines[_m], _s, _s, c_white, 1.0);
        }
    } catch (_e) {
        mmapi_warn_rate_limited("mt_hud", MT_MOD, "hud draw failed: " + string(_e));
    }
}

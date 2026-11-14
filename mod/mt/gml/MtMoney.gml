// Mistria Together - MtMoney.gml: wallets and the shipping bin.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Separate wallets (default): every game would pay out the whole shipping bin
// at its own overnight summary. Instead the host totals the bin when the night
// starts and splits it evenly between the players online; each game cancels
// its local payout (player.gold_delta filter) and pays its share once the new
// morning is in place. Everything else a player earns or spends is their own.

function mt_money_state() {
    var _rt = __mt_rt();
    if (_rt[$ "money"] == undefined) {
        _rt.money = {
            plan: undefined,        // { day, bin, share } from the host's `ng`
            cancelled: false,       // the local bin payout was held back this night
            local_bin: 0,           // what the local game would have paid
            paying: false,
            paid_day: -1,
            last_share: 0,
            // wallet mode (host decides): "separate" or "shared"
            mode: "separate",
            pending: "",            // host: mode to apply at the next morning
            balance_sent: -1,       // host: last shared balance broadcast
            golds: {},              // host: each guest's last reported gold (separate mode)
            gold_reported: -1,      // guest: last gold reported to the host
            personal: undefined,    // guest: own gold put aside while the wallet is shared
            seq: 0,
        };
    }
    return _rt.money;
}

// --- pure logic --------------------------------------------------------------------

// Even split of `_total` between `_ids`; the remainder goes to `_host_id`.
function mt_money_split(_total, _ids, _host_id) {
    var _shares = {};
    var _n = array_length(_ids);
    if (_n == 0) { return _shares; }
    var _base = floor(_total / _n);
    var _rest = _total - _base * _n;
    for (var _i = 0; _i < _n; _i++) {
        _shares[$ string(_ids[_i])] = _base + (_ids[_i] == _host_id ? _rest : 0);
    }
    return _shares;
}

// --- the bin ---------------------------------------------------------------------------

// What the shipping bins would pay right now (the game's own valuation).
function mt_money_bin_total() {
    var _total = 0;
    var _bins = shipping_bins();
    for (var _b = 0; _b < _bins.count(); _b++) {
        var _slots = _bins.get(_b).inventory.slots;
        for (var _s = 0; _s < _slots.count(); _s++) {
            var _slot = _slots.get(_s);
            if (_slot.item != undefined && _slot.count > 0) { _total += _slot.item.bin_value() * _slot.count; }
        }
    }
    return _total;
}

// --- night and morning ----------------------------------------------------------------

// `ng` arrived (or the host started the night): remember this player's share.
function mt_money_on_night(_day, _bin, _shares) {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    var _share = is_struct(_shares) ? (_shares[$ string(_rt.self_id)] ?? 0) : 0;
    _m.plan = { day: _day, bin: _bin, share: _share };
}

// player.gold_delta filter: hold back the local bin payout while others are online.
function mt_money_filter_gold(_value, _ctx) {
    if (_value == undefined) { return undefined; }
    var _m = mt_money_state();
    if (_m.paying || !mt_night_active() || ARI == undefined) { return undefined; }
    if (!_m.cancelled && ARI.end_of_day_sequence == true) {
        // The first change during the overnight summary is the shipping bin's.
        _m.cancelled = true;
        _m.local_bin = _value;
        return 0;
    }
    if (_m.mode == "shared") {
        if (mt_is_host()) { return max(_value, -ARI.gold); }    // the host's gold is the ledger
        if (_value != 0) {
            _m.seq += 1;
            mt_send(MT_TO_HOST, { t: "gd", a: _value, q: _m.seq });
        }
        return 0;       // applied when the host's balance comes back
    }
    return undefined;
}

// game.new_day: the morning is in place, pay this player's share once.
function mt_money_on_new_day(_ctx) {
    var _m = mt_money_state();
    mt_money_pay_share();
    if (mt_is_host() && _m.pending != "" && mt_night_active()) { mt_money_apply_mode(_m.pending); }
}

function mt_money_pay_share() {
    var _m = mt_money_state();
    if (!_m.cancelled && _m.plan == undefined) { return; }
    var _share = _m.local_bin;      // fallback: nobody planned it (the host left)
    var _bin = _m.local_bin;
    var _day = -2;
    if (_m.plan != undefined) { _share = _m.plan.share; _bin = _m.plan.bin; _day = _m.plan.day; }
    var _cancelled = _m.cancelled;
    _m.plan = undefined;
    _m.cancelled = false;
    _m.local_bin = 0;
    if (_day == _m.paid_day || !_cancelled) { return; }   // never twice, never without a held payout
    _m.paid_day = _day;
    _m.last_share = _share;
    try {
        _m.paying = true;
        ARI.modify_gold(_share);
    } catch (_e) {
        mmapi_warn_rate_limited("mt_money_pay", MT_MOD, "could not pay the shipping share: " + string(_e));
    }
    _m.paying = false;
    mt_ui_toast("Shipping: " + string(_bin) + "g, your share " + string(_share) + "g");
}

function mt_money_dev_state() {
    var _m = mt_money_state();
    return { mode: _m.mode, pending: _m.pending, cancelled: _m.cancelled, paid_day: _m.paid_day, last_share: _m.last_share, planned: _m.plan != undefined };
}


// --- wallet modes ------------------------------------------------------------------------

function mt_money_shared() {
    return mt_night_active() && mt_money_state().mode == "shared";
}

// Host: ask for a wallet mode; it takes effect at the next morning.
function mt_money_request_mode(_mode) {
    if (!mt_is_host()) { return; }
    var _m = mt_money_state();
    _m.pending = (_mode == _m.mode) ? "" : _mode;
    mt_ui_toast(_m.pending == "" ? "Wallet stays " + _m.mode : "Wallet becomes " + _mode + " tomorrow morning");
}

// Host: switch now (used at the morning, and by tests).
function mt_money_apply_mode(_mode) {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    if (!mt_is_host() || _mode == _m.mode) { return; }
    var _ids = [_rt.self_id];
    for (var _i = 0; _i < array_length(_rt.peer_ids); _i++) { array_push(_ids, _rt.peer_ids[_i]); }
    _m.paying = true;
    if (_mode == "shared") {
        var _sum = ARI.gold;
        for (var _g = 0; _g < array_length(_rt.peer_ids); _g++) { _sum += (_m.golds[$ string(_rt.peer_ids[_g])] ?? 0); }
        _m.mode = "shared";
        ARI.set_gold(_sum);
        _m.balance_sent = _sum;
        mt_send(MT_TO_ALL, { t: "gm", mode: "shared", balance: _sum });
    } else {
        var _shares = mt_money_split(ARI.gold, _ids, _rt.self_id);
        _m.mode = "separate";
        ARI.set_gold(_shares[$ string(_rt.self_id)] ?? 0);
        _m.balance_sent = -1;
        mt_send(MT_TO_ALL, { t: "gm", mode: "separate", shares: _shares });
    }
    _m.paying = false;
    _m.pending = "";
    mt_ui_toast("Wallet is now " + _m.mode);
}

// Guest: the mode changed (or we just joined).
function mt_money_on_mode(_d) {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    var _f = mt_farm_state();
    _m.paying = true;
    if (_d[$ "mode"] == "shared") {
        if (_m.mode != "shared") {
            var _own = is_struct(_f.tag) && _f.tag[$ "personal"] != undefined ? _f.tag.personal : ARI.gold;
            _m.personal = _own;
            if (is_struct(_f.tag)) { _f.tag.personal = _own; }
        }
        _m.mode = "shared";
        ARI.set_gold(_d[$ "balance"] ?? ARI.gold);
    } else {
        _m.mode = "separate";
        var _shares = _d[$ "shares"];
        if (is_struct(_shares) && _shares[$ string(_rt.self_id)] != undefined) {
            ARI.set_gold(_shares[$ string(_rt.self_id)]);
        } else if (_m.personal != undefined) {
            ARI.set_gold(_m.personal);
        }
        _m.personal = undefined;
        if (is_struct(_f.tag)) { struct_remove(_f.tag, "personal"); }
    }
    _m.paying = false;
}

// The session ended: a guest gets their own gold back.
function mt_money_reset() {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    // Only a guest has a put-aside personal balance (the ids are already gone here).
    if (_m.personal != undefined) {
        if (ARI != undefined) {
            _m.paying = true;
            ARI.set_gold(_m.personal);
            _m.paying = false;
        }
        _m.mode = "separate";
    }
    _m.personal = undefined;
    _m.pending = "";
    _m.golds = {};
    _m.gold_reported = -1;
    _m.balance_sent = -1;
}

// Host: a newcomer learns the wallet.
function mt_money_on_peer_joined(_id) {
    var _m = mt_money_state();
    if (!mt_is_host()) { return; }
    if (_m.mode == "shared") { mt_send(_id, { t: "gm", mode: "shared", balance: ARI.gold }); }
}

function mt_money_on_message(_peer, _t, _d) {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    switch (_t) {
        case "gd":      // guest -> host: a change of the shared balance
            if (!mt_is_host() || _m.mode != "shared") { break; }
            if (ARI.gold + _d.a < 0) {
                mt_send(_peer.id, { t: "gx", q: _d[$ "q"] });
            } else {
                _m.paying = true;
                ARI.modify_gold(_d.a);
                _m.paying = false;
            }
            break;
        case "gx":
            if (_peer.id == _rt.host_id) { mt_ui_toast("Not enough gold in the shared wallet"); }
            break;
        case "gb":      // host -> all: the shared balance
            if (_peer.id != _rt.host_id || _m.mode != "shared") { break; }
            _m.paying = true;
            ARI.set_gold(_d.b);
            _m.paying = false;
            break;
        case "gm":
            if (_peer.id == _rt.host_id) { mt_money_on_mode(_d); }
            break;
        case "gr":      // guest -> host: own gold, for a later switch to shared
            if (mt_is_host()) { _m.golds[$ string(_peer.id)] = _d.g; }
            break;
    }
}

// Per frame while online with others.
function mt_money_tick() {
    var _rt = __mt_rt();
    var _m = mt_money_state();
    if (!mt_night_active() || ARI == undefined) { return; }
    if (mt_is_host()) {
        if (_m.mode == "shared" && ARI.gold != _m.balance_sent) {
            _m.balance_sent = ARI.gold;
            mt_send(MT_TO_ALL, { t: "gb", b: ARI.gold });
        }
    } else if (_m.mode == "separate" && ARI.gold != _m.gold_reported && _rt.frame % 30 == 0) {
        _m.gold_reported = ARI.gold;
        mt_send(MT_TO_HOST, { t: "gr", g: ARI.gold });
    }
}

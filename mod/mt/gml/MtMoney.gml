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
    if (_m.paying || !mt_night_active() || _m.cancelled) { return undefined; }
    if (ARI == undefined || ARI.end_of_day_sequence != true) { return undefined; }
    // The first change during the overnight summary is the shipping bin's.
    _m.cancelled = true;
    _m.local_bin = _value;
    return 0;
}

// game.new_day: the morning is in place, pay this player's share once.
function mt_money_on_new_day(_ctx) {
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
    return { cancelled: _m.cancelled, paid_day: _m.paid_day, last_share: _m.last_share, planned: _m.plan != undefined };
}

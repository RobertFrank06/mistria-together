// Mistria Together - MtSync.gml: shared farm state.
// SPDX-License-Identifier: GPL-3.0-or-later

function mt_sync_reset() {
}

function mt_sync_on_online() {
}

function mt_sync_on_peer_joined(_id) {
}

function mt_sync_tick() {
}

function mt_sync_on_host_day(_cal) {
    CALENDAR.time = _cal;
}

function mt_sync_on_message(_peer, _t, _d) {
}

function mt_sync_on_blob(_d) {
}

function mt_sync_on_new_day(_ctx) {
}

function mt_sync_save_guard(_ctx) {
    return undefined;
}

function mt_sync_dev_command(_cmd) {
}

function mt_sync_dev_state() {
    return {};
}

// =============================================================================
// Colyseus GameMaker WASM Shim
// Maps C-exported functions from the WASM module to global scope for GameMaker.
// This file is concatenated after the Emscripten MODULARIZE output.
// =============================================================================
(function() {
    "use strict";

    var _mod = null;

    // Emscripten's FETCH library init calls addRunDependency/removeRunDependency.
    // In a MODULARIZE build running inside GameMaker (itself an Emscripten app),
    // these may not be in scope. Provide global stubs so the init succeeds.
    // The actual fetch() calls work independently of this init.
    if (typeof addRunDependency === 'undefined') {
        window.addRunDependency = function() {};
        window.removeRunDependency = function() {};
    }

    // Instantiate the Colyseus WASM module
    if (typeof ColyseusModule === 'function') {
        ColyseusModule().then(function(mod) {
            _mod = mod;
            console.log("[Colyseus WASM] Module initialized.");
        }).catch(function(err) {
            console.error("[Colyseus WASM] Failed to initialize:", err);
        });
    } else {
        console.error("[Colyseus WASM] ColyseusModule not found. Was the WASM module built?");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _callN(name, argTypes, args) {
        if (!_mod) { return 0; }
        return _mod.ccall(name, 'number', argTypes, args);
    }

    function _callS(name, argTypes, args) {
        if (!_mod) { return ""; }
        return _mod.ccall(name, 'string', argTypes, args);
    }

    function _callV(name, argTypes, args) {
        if (!_mod) { return; }
        _mod.ccall(name, null, argTypes, args);
    }

    // =========================================================================
    // Module readiness check (JS-only, no WASM call needed)
    // =========================================================================

    window.colyseus_gm_is_ready = function() {
        return _mod ? 1 : 0;
    };

    // =========================================================================
    // Client functions
    // =========================================================================

    window.colyseus_gm_client_create = function(endpoint) {
        return _callN('colyseus_gm_client_create', ['string'], [endpoint]);
    };

    window.colyseus_gm_client_free = function(h) {
        _callV('colyseus_gm_client_free', ['number'], [h]);
    };

    window.colyseus_gm_client_join_or_create = function(client, room, opts) {
        return _callN('colyseus_gm_client_join_or_create', ['number', 'string', 'string'], [client, room, opts]);
    };

    window.colyseus_gm_client_create_room = function(client, room, opts) {
        return _callN('colyseus_gm_client_create_room', ['number', 'string', 'string'], [client, room, opts]);
    };

    window.colyseus_gm_client_join = function(client, room, opts) {
        return _callN('colyseus_gm_client_join', ['number', 'string', 'string'], [client, room, opts]);
    };

    window.colyseus_gm_client_join_by_id = function(client, id, opts) {
        return _callN('colyseus_gm_client_join_by_id', ['number', 'string', 'string'], [client, id, opts]);
    };

    window.colyseus_gm_client_reconnect = function(client, token) {
        return _callN('colyseus_gm_client_reconnect', ['number', 'string'], [client, token]);
    };

    // =========================================================================
    // Room functions
    // =========================================================================

    window.colyseus_gm_room_leave = function(h) {
        _callV('colyseus_gm_room_leave', ['number'], [h]);
    };

    window.colyseus_gm_room_free = function(h) {
        _callV('colyseus_gm_room_free', ['number'], [h]);
    };

    window.colyseus_gm_room_send = function(h, type, data) {
        _callV('colyseus_gm_room_send', ['number', 'string', 'string'], [h, type, data]);
    };

    window.colyseus_gm_room_send_bytes = function(h, type, dataPtr, len) {
        _callV('colyseus_gm_room_send_bytes', ['number', 'string', 'number', 'number'], [h, type, dataPtr, len]);
    };

    window.colyseus_gm_room_send_int = function(h, type, data) {
        _callV('colyseus_gm_room_send_int', ['number', 'number', 'string'], [h, type, data]);
    };

    window.colyseus_gm_room_get_id = function(h) {
        return _callS('colyseus_gm_room_get_id', ['number'], [h]);
    };

    window.colyseus_gm_room_get_session_id = function(h) {
        return _callS('colyseus_gm_room_get_session_id', ['number'], [h]);
    };

    window.colyseus_gm_room_get_name = function(h) {
        return _callS('colyseus_gm_room_get_name', ['number'], [h]);
    };

    window.colyseus_gm_room_has_joined = function(h) {
        return _callN('colyseus_gm_room_has_joined', ['number'], [h]);
    };

    // =========================================================================
    // State access functions
    // =========================================================================

    window.colyseus_gm_room_get_state = function(h) {
        return _callN('colyseus_gm_room_get_state', ['number'], [h]);
    };

    window.colyseus_gm_schema_get_string = function(inst, field) {
        return _callS('colyseus_gm_schema_get_string', ['number', 'string'], [inst, field]);
    };

    window.colyseus_gm_schema_get_number = function(inst, field) {
        return _callN('colyseus_gm_schema_get_number', ['number', 'string'], [inst, field]);
    };

    window.colyseus_gm_schema_get_ref = function(inst, field) {
        return _callN('colyseus_gm_schema_get_ref', ['number', 'string'], [inst, field]);
    };

    window.colyseus_gm_map_get = function(inst, field, key) {
        return _callN('colyseus_gm_map_get', ['number', 'string', 'string'], [inst, field, key]);
    };

    // =========================================================================
    // Callbacks functions
    // =========================================================================

    window.colyseus_gm_callbacks_create = function(h) {
        return _callN('colyseus_gm_callbacks_create', ['number'], [h]);
    };

    window.colyseus_gm_callbacks_free = function(h) {
        _callV('colyseus_gm_callbacks_free', ['number'], [h]);
    };

    window.colyseus_gm_callbacks_remove_handle = function(cb, h) {
        _callV('colyseus_gm_callbacks_remove_handle', ['number', 'number'], [cb, h]);
    };

    window.colyseus_gm_callbacks_listen = function(cb, inst, prop) {
        return _callN('colyseus_gm_callbacks_listen', ['number', 'number', 'string'], [cb, inst, prop]);
    };

    window.colyseus_gm_callbacks_on_add = function(cb, inst, prop) {
        return _callN('colyseus_gm_callbacks_on_add', ['number', 'number', 'string'], [cb, inst, prop]);
    };

    window.colyseus_gm_callbacks_on_remove = function(cb, inst, prop) {
        return _callN('colyseus_gm_callbacks_on_remove', ['number', 'number', 'string'], [cb, inst, prop]);
    };

    // =========================================================================
    // Event polling functions
    // =========================================================================

    window.colyseus_gm_poll_event = function() {
        return _callN('colyseus_gm_poll_event', [], []);
    };

    window.colyseus_gm_event_get_room = function() {
        return _callN('colyseus_gm_event_get_room', [], []);
    };

    window.colyseus_gm_event_get_code = function() {
        return _callN('colyseus_gm_event_get_code', [], []);
    };

    window.colyseus_gm_event_get_message = function() {
        return _callS('colyseus_gm_event_get_message', [], []);
    };

    window.colyseus_gm_event_get_data = function() {
        return _callN('colyseus_gm_event_get_data', [], []);
    };

    window.colyseus_gm_event_get_data_length = function() {
        return _callN('colyseus_gm_event_get_data_length', [], []);
    };

    // Schema event accessors
    window.colyseus_gm_event_get_callback_handle = function() {
        return _callN('colyseus_gm_event_get_callback_handle', [], []);
    };

    window.colyseus_gm_event_get_instance = function() {
        return _callN('colyseus_gm_event_get_instance', [], []);
    };

    window.colyseus_gm_event_get_value_number = function() {
        return _callN('colyseus_gm_event_get_value_number', [], []);
    };

    window.colyseus_gm_event_get_value_string = function() {
        return _callS('colyseus_gm_event_get_value_string', [], []);
    };

    window.colyseus_gm_event_get_prev_value_number = function() {
        return _callN('colyseus_gm_event_get_prev_value_number', [], []);
    };

    window.colyseus_gm_event_get_prev_value_string = function() {
        return _callS('colyseus_gm_event_get_prev_value_string', [], []);
    };

    window.colyseus_gm_event_get_key_string = function() {
        return _callS('colyseus_gm_event_get_key_string', [], []);
    };

    window.colyseus_gm_event_get_value_type = function() {
        return _callN('colyseus_gm_event_get_value_type', [], []);
    };

    // =========================================================================
    // Message builder functions
    // =========================================================================

    window.colyseus_gm_message_create_map = function() {
        return _callN('colyseus_gm_message_create_map', [], []);
    };

    window.colyseus_gm_message_put_str = function(msg, key, val) {
        _callV('colyseus_gm_message_put_str', ['number', 'string', 'string'], [msg, key, val]);
    };

    window.colyseus_gm_message_put_number = function(msg, key, val) {
        _callV('colyseus_gm_message_put_number', ['number', 'string', 'number'], [msg, key, val]);
    };

    window.colyseus_gm_message_put_bool = function(msg, key, val) {
        _callV('colyseus_gm_message_put_bool', ['number', 'string', 'number'], [msg, key, val]);
    };

    window.colyseus_gm_message_free = function(h) {
        _callV('colyseus_gm_message_free', ['number'], [h]);
    };

    window.colyseus_gm_room_send_message = function(room, type, msg) {
        _callV('colyseus_gm_room_send_message', ['number', 'string', 'number'], [room, type, msg]);
    };

    // =========================================================================
    // Message reader functions
    // =========================================================================

    window.colyseus_gm_message_get_type = function() {
        return _callN('colyseus_gm_message_get_type', [], []);
    };

    window.colyseus_gm_message_read_string = function(key) {
        return _callS('colyseus_gm_message_read_string', ['string'], [key]);
    };

    window.colyseus_gm_message_read_number = function(key) {
        return _callN('colyseus_gm_message_read_number', ['string'], [key]);
    };

    window.colyseus_gm_message_read_bool = function(key) {
        return _callN('colyseus_gm_message_read_bool', ['string'], [key]);
    };

    window.colyseus_gm_message_read_string_value = function() {
        return _callS('colyseus_gm_message_read_string_value', [], []);
    };

    window.colyseus_gm_message_read_number_value = function() {
        return _callN('colyseus_gm_message_read_number_value', [], []);
    };

    // =========================================================================
    // Message map iterator functions
    // =========================================================================

    window.colyseus_gm_message_map_size = function() {
        return _callN('colyseus_gm_message_map_size', [], []);
    };

    window.colyseus_gm_message_iter_begin = function() {
        _callV('colyseus_gm_message_iter_begin', [], []);
    };

    window.colyseus_gm_message_iter_next = function() {
        return _callN('colyseus_gm_message_iter_next', [], []);
    };

    window.colyseus_gm_message_iter_key = function() {
        return _callS('colyseus_gm_message_iter_key', [], []);
    };

    window.colyseus_gm_message_iter_value_type = function() {
        return _callN('colyseus_gm_message_iter_value_type', [], []);
    };

    window.colyseus_gm_message_iter_value_string = function() {
        return _callS('colyseus_gm_message_iter_value_string', [], []);
    };

    window.colyseus_gm_message_iter_value_number = function() {
        return _callN('colyseus_gm_message_iter_value_number', [], []);
    };

})();

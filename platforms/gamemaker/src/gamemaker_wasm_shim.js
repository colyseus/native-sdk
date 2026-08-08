// =============================================================================
// Colyseus GameMaker WASM Shim
// Maps C-exported functions from the WASM module to global scope for GameMaker.
// This file is concatenated after the Emscripten MODULARIZE output.
//
// The block between the GENERATED BINDINGS markers is emitted by
// ../gen-bindings.mjs from the C sources — do not edit it by hand. Hand-
// written functions (module readiness, JS-fetch HTTP) live outside it.
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
        try { return _mod.ccall(name, 'number', argTypes, args); }
        catch(e) { console.error("[Colyseus WASM] ccall error (" + name + "):", e); return 0; }
    }

    function _callS(name, argTypes, args) {
        if (!_mod) { return ""; }
        try { return _mod.ccall(name, 'string', argTypes, args); }
        catch(e) { console.error("[Colyseus WASM] ccall error (" + name + "):", e); return ""; }
    }

    function _callV(name, argTypes, args) {
        if (!_mod) { return; }
        try { _mod.ccall(name, null, argTypes, args); }
        catch(e) { console.error("[Colyseus WASM] ccall error (" + name + "):", e); }
    }

    // =========================================================================
    // Module readiness check (JS-only, no WASM call needed)
    // =========================================================================

    window.colyseus_gm_is_ready = function() {
        return _mod ? 1 : 0;
    };

    // =========================================================================
    // HTTP functions (implemented via JS fetch — results are pushed back into
    // the WASM event queue through colyseus_gm_http_push_response/error)
    // =========================================================================

    var _httpRequestCounter = 0;

    function _httpRequest(clientHandle, method, path, body) {
        var requestId = ++_httpRequestCounter;

        // Get base URL and auth token from the WASM module
        var endpoint = _callS('colyseus_gm_http_get_endpoint', ['number'], [clientHandle]);
        if (!endpoint) {
            _callV('colyseus_gm_http_push_error', ['number', 'number', 'string'],
                [requestId, 0, 'No endpoint configured']);
            return requestId;
        }

        // Build full URL
        var url = endpoint;
        if (path) {
            var endsWithSlash = url.charAt(url.length - 1) === '/';
            var startsWithSlash = path.charAt(0) === '/';
            if (endsWithSlash && startsWithSlash) {
                url = url + path.substring(1);
            } else if (!endsWithSlash && !startsWithSlash) {
                url = url + '/' + path;
            } else {
                url = url + path;
            }
        }

        var authToken = _callS('colyseus_gm_auth_get_token', ['number'], [clientHandle]);

        var fetchOptions = {
            method: method,
            headers: { 'Content-Type': 'application/json' }
        };

        if (authToken) {
            fetchOptions.headers['Authorization'] = 'Bearer ' + authToken;
        }

        if (body) {
            fetchOptions.body = body;
        }

        fetch(url, fetchOptions).then(function(response) {
            return response.text().then(function(text) {
                if (response.ok) {
                    _callV('colyseus_gm_http_push_response', ['number', 'number', 'string'],
                        [requestId, response.status, text]);
                } else {
                    _callV('colyseus_gm_http_push_error', ['number', 'number', 'string'],
                        [requestId, response.status, text]);
                }
            });
        }).catch(function(err) {
            _callV('colyseus_gm_http_push_error', ['number', 'number', 'string'],
                [requestId, 0, err.message || 'Network error']);
        });

        return requestId;
    }

    window.colyseus_gm_http_get = function(clientHandle, path) {
        return _httpRequest(clientHandle, 'GET', path, null);
    };

    window.colyseus_gm_http_post = function(clientHandle, path, body) {
        return _httpRequest(clientHandle, 'POST', path, body);
    };

    window.colyseus_gm_http_put = function(clientHandle, path, body) {
        return _httpRequest(clientHandle, 'PUT', path, body);
    };

    window.colyseus_gm_http_delete = function(clientHandle, path) {
        return _httpRequest(clientHandle, 'DELETE', path, null);
    };

    window.colyseus_gm_http_patch = function(clientHandle, path, body) {
        return _httpRequest(clientHandle, 'PATCH', path, body);
    };

    // === GENERATED BINDINGS BEGIN (gen-bindings.mjs) ===

    window.colyseus_gm_client_create = function(endpoint) {
        return _callN('colyseus_gm_client_create', ['string'], [endpoint]);
    };

    window.colyseus_gm_client_free = function(client_handle) {
        _callV('colyseus_gm_client_free', ['number'], [client_handle]);
    };

    window.colyseus_gm_client_join_or_create = function(client_handle, room_name, options_json) {
        return _callN('colyseus_gm_client_join_or_create', ['number', 'string', 'string'], [client_handle, room_name, options_json]);
    };

    window.colyseus_gm_client_create_room = function(client_handle, room_name, options_json) {
        return _callN('colyseus_gm_client_create_room', ['number', 'string', 'string'], [client_handle, room_name, options_json]);
    };

    window.colyseus_gm_client_join = function(client_handle, room_name, options_json) {
        return _callN('colyseus_gm_client_join', ['number', 'string', 'string'], [client_handle, room_name, options_json]);
    };

    window.colyseus_gm_client_join_by_id = function(client_handle, room_id, options_json) {
        return _callN('colyseus_gm_client_join_by_id', ['number', 'string', 'string'], [client_handle, room_id, options_json]);
    };

    window.colyseus_gm_client_reconnect = function(client_handle, reconnection_token) {
        return _callN('colyseus_gm_client_reconnect', ['number', 'string'], [client_handle, reconnection_token]);
    };

    window.colyseus_gm_room_leave = function(room_handle) {
        _callV('colyseus_gm_room_leave', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_free = function(room_handle) {
        _callV('colyseus_gm_room_free', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_send = function(room_handle, type, data) {
        _callV('colyseus_gm_room_send', ['number', 'string', 'string'], [room_handle, type, data]);
    };

    window.colyseus_gm_room_send_bytes = function(room_handle, type, data, length) {
        _callV('colyseus_gm_room_send_bytes', ['number', 'string', 'number', 'number'], [room_handle, type, data, length]);
    };

    window.colyseus_gm_room_send_int = function(room_handle, type, data) {
        _callV('colyseus_gm_room_send_int', ['number', 'number', 'string'], [room_handle, type, data]);
    };

    window.colyseus_gm_room_get_id = function(room_handle) {
        return _callS('colyseus_gm_room_get_id', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_get_session_id = function(room_handle) {
        return _callS('colyseus_gm_room_get_session_id', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_get_name = function(room_handle) {
        return _callS('colyseus_gm_room_get_name', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_is_connected = function(room_handle) {
        return _callN('colyseus_gm_room_is_connected', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_is_reconnecting = function(room_handle) {
        return _callN('colyseus_gm_room_is_reconnecting', ['number'], [room_handle]);
    };

    window.colyseus_gm_room_set_reconnection_options = function(room_handle, enabled, max_retries, min_delay_ms, max_delay_ms, min_uptime_ms, delay_ms, max_enqueued_messages) {
        _callV('colyseus_gm_room_set_reconnection_options', ['number', 'number', 'number', 'number', 'number', 'number', 'number', 'number'], [room_handle, enabled, max_retries, min_delay_ms, max_delay_ms, min_uptime_ms, delay_ms, max_enqueued_messages]);
    };

    window.colyseus_gm_room_get_state = function(room_handle) {
        return _callN('colyseus_gm_room_get_state', ['number'], [room_handle]);
    };

    window.colyseus_gm_schema_get_string = function(instance_handle, field_name) {
        return _callS('colyseus_gm_schema_get_string', ['number', 'string'], [instance_handle, field_name]);
    };

    window.colyseus_gm_schema_get_field_type = function(instance_handle, field_name) {
        return _callN('colyseus_gm_schema_get_field_type', ['number', 'string'], [instance_handle, field_name]);
    };

    window.colyseus_gm_schema_get_number = function(instance_handle, field_name) {
        return _callN('colyseus_gm_schema_get_number', ['number', 'string'], [instance_handle, field_name]);
    };

    window.colyseus_gm_schema_get = function(instance_handle, field_name) {
        return _callN('colyseus_gm_schema_get', ['number', 'string'], [instance_handle, field_name]);
    };

    window.colyseus_gm_schema_get_result_string = function() {
        return _callS('colyseus_gm_schema_get_result_string', [], []);
    };

    window.colyseus_gm_schema_get_result_number = function() {
        return _callN('colyseus_gm_schema_get_result_number', [], []);
    };

    window.colyseus_gm_schema_field_count = function(instance_handle) {
        return _callN('colyseus_gm_schema_field_count', ['number'], [instance_handle]);
    };

    window.colyseus_gm_schema_field_name = function(instance_handle, index) {
        return _callS('colyseus_gm_schema_field_name', ['number', 'number'], [instance_handle, index]);
    };

    window.colyseus_gm_schema_field_type_at = function(instance_handle, index) {
        return _callN('colyseus_gm_schema_field_type_at', ['number', 'number'], [instance_handle, index]);
    };

    window.colyseus_gm_map_get = function(instance_handle, field_name, key) {
        return _callN('colyseus_gm_map_get', ['number', 'string', 'string'], [instance_handle, field_name, key]);
    };

    window.colyseus_gm_callbacks_create = function(room_handle) {
        return _callN('colyseus_gm_callbacks_create', ['number'], [room_handle]);
    };

    window.colyseus_gm_callbacks_free = function(callbacks_handle) {
        _callV('colyseus_gm_callbacks_free', ['number'], [callbacks_handle]);
    };

    window.colyseus_gm_callbacks_remove_handle = function(callbacks_handle, callback_handle) {
        _callV('colyseus_gm_callbacks_remove_handle', ['number', 'number'], [callbacks_handle, callback_handle]);
    };

    window.colyseus_gm_callbacks_listen = function(callbacks_handle, instance_handle, property) {
        return _callN('colyseus_gm_callbacks_listen', ['number', 'number', 'string'], [callbacks_handle, instance_handle, property]);
    };

    window.colyseus_gm_callbacks_on_add = function(callbacks_handle, instance_handle, property) {
        return _callN('colyseus_gm_callbacks_on_add', ['number', 'number', 'string'], [callbacks_handle, instance_handle, property]);
    };

    window.colyseus_gm_callbacks_on_remove = function(callbacks_handle, instance_handle, property) {
        return _callN('colyseus_gm_callbacks_on_remove', ['number', 'number', 'string'], [callbacks_handle, instance_handle, property]);
    };

    window.colyseus_gm_callbacks_on_change_instance = function(callbacks_handle, instance_handle) {
        return _callN('colyseus_gm_callbacks_on_change_instance', ['number', 'number'], [callbacks_handle, instance_handle]);
    };

    window.colyseus_gm_callbacks_on_change_collection = function(callbacks_handle, instance_handle, property) {
        return _callN('colyseus_gm_callbacks_on_change_collection', ['number', 'number', 'string'], [callbacks_handle, instance_handle, property]);
    };

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

    window.colyseus_gm_message_create_map = function() {
        return _callN('colyseus_gm_message_create_map', [], []);
    };

    window.colyseus_gm_message_put_str = function(msg_handle, key, value) {
        _callV('colyseus_gm_message_put_str', ['number', 'string', 'string'], [msg_handle, key, value]);
    };

    window.colyseus_gm_message_put_number = function(msg_handle, key, value) {
        _callV('colyseus_gm_message_put_number', ['number', 'string', 'number'], [msg_handle, key, value]);
    };

    window.colyseus_gm_message_put_bool = function(msg_handle, key, value) {
        _callV('colyseus_gm_message_put_bool', ['number', 'string', 'number'], [msg_handle, key, value]);
    };

    window.colyseus_gm_message_free = function(msg_handle) {
        _callV('colyseus_gm_message_free', ['number'], [msg_handle]);
    };

    window.colyseus_gm_room_send_message = function(room_handle, type, msg_handle) {
        _callV('colyseus_gm_room_send_message', ['number', 'string', 'number'], [room_handle, type, msg_handle]);
    };

    window.colyseus_gm_message_create_bool = function(value) {
        return _callN('colyseus_gm_message_create_bool', ['number'], [value]);
    };

    window.colyseus_gm_message_create_number = function(value) {
        return _callN('colyseus_gm_message_create_number', ['number'], [value]);
    };

    window.colyseus_gm_message_create_int = function(value) {
        return _callN('colyseus_gm_message_create_int', ['number'], [value]);
    };

    window.colyseus_gm_message_create_string = function(value) {
        return _callN('colyseus_gm_message_create_string', ['string'], [value]);
    };

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

    window.colyseus_gm_auth_set_token = function(client_handle, token) {
        _callV('colyseus_gm_auth_set_token', ['number', 'string'], [client_handle, token]);
    };

    window.colyseus_gm_auth_get_token = function(client_handle) {
        return _callS('colyseus_gm_auth_get_token', ['number'], [client_handle]);
    };

    window.colyseus_gm_event_get_http_status = function() {
        return _callN('colyseus_gm_event_get_http_status', [], []);
    };

    window.colyseus_gm_event_get_http_body = function() {
        return _callS('colyseus_gm_event_get_http_body', [], []);
    };

    window.colyseus_gm_get_latency = function(client_handle, endpoint, timeout_ms) {
        return _callN('colyseus_gm_get_latency', ['number', 'string', 'number'], [client_handle, endpoint, timeout_ms]);
    };

    window.colyseus_gm_select_by_latency = function(client_handle, endpoints_json, timeout_ms) {
        return _callN('colyseus_gm_select_by_latency', ['number', 'string', 'number'], [client_handle, endpoints_json, timeout_ms]);
    };

    window.colyseus_gm_event_get_latency = function() {
        return _callN('colyseus_gm_event_get_latency', [], []);
    };

    window.colyseus_gm_http_push_response = function(request_id, status_code, body) {
        _callV('colyseus_gm_http_push_response', ['number', 'number', 'string'], [request_id, status_code, body]);
    };

    window.colyseus_gm_http_push_error = function(request_id, code, message) {
        _callV('colyseus_gm_http_push_error', ['number', 'number', 'string'], [request_id, code, message]);
    };

    window.colyseus_gm_latency_push_response = function(request_id, latency_ms, endpoint) {
        _callV('colyseus_gm_latency_push_response', ['number', 'number', 'string'], [request_id, latency_ms, endpoint]);
    };

    window.colyseus_gm_latency_push_error = function(request_id, code, message) {
        _callV('colyseus_gm_latency_push_error', ['number', 'number', 'string'], [request_id, code, message]);
    };

    window.colyseus_gm_latency_push_selected = function(request_id, best_endpoint, latency_ms) {
        _callV('colyseus_gm_latency_push_selected', ['number', 'string', 'number'], [request_id, best_endpoint, latency_ms]);
    };

    window.colyseus_gm_http_get_endpoint = function(client_handle) {
        return _callS('colyseus_gm_http_get_endpoint', ['number'], [client_handle]);
    };

    window.colyseus_gm_predict_abi_version = function() {
        return _callN('colyseus_gm_predict_abi_version', [], []);
    };

    window.colyseus_gm_now = function() {
        return _callN('colyseus_gm_now', [], []);
    };

    window.colyseus_gm_clock_stat = function(clock_h, which) {
        return _callN('colyseus_gm_clock_stat', ['number', 'number'], [clock_h, which]);
    };

    window.colyseus_gm_reconnect_poll = function() {
        _callV('colyseus_gm_reconnect_poll', [], []);
    };

    window.colyseus_gm_input_init = function(room_ref, unreliable, history_size, render_delay) {
        return _callN('colyseus_gm_input_init', ['number', 'number', 'number', 'number'], [room_ref, unreliable, history_size, render_delay]);
    };

    window.colyseus_gm_input_set = function(input_h, field, value) {
        return _callN('colyseus_gm_input_set', ['number', 'string', 'number'], [input_h, field, value]);
    };

    window.colyseus_gm_input_get = function(input_h, field) {
        return _callN('colyseus_gm_input_get', ['number', 'string'], [input_h, field]);
    };

    window.colyseus_gm_input_send = function(input_h) {
        return _callN('colyseus_gm_input_send', ['number'], [input_h]);
    };

    window.colyseus_gm_input_stat = function(input_h, which) {
        return _callN('colyseus_gm_input_stat', ['number', 'number'], [input_h, which]);
    };

    window.colyseus_gm_input_set_render_delay = function(input_h, ms) {
        _callV('colyseus_gm_input_set_render_delay', ['number', 'number'], [input_h, ms]);
    };

    window.colyseus_gm_input_reset = function(input_h) {
        _callV('colyseus_gm_input_reset', ['number'], [input_h]);
    };

    window.colyseus_gm_input_set_rewind_field = function(input_h, field) {
        return _callN('colyseus_gm_input_set_rewind_field', ['number', 'string'], [input_h, field]);
    };

    window.colyseus_gm_predict_create = function(room_ref) {
        return _callN('colyseus_gm_predict_create', ['number'], [room_ref]);
    };

    window.colyseus_gm_predict_create_with = function(callbacks_ptr, clock_ptr) {
        return _callN('colyseus_gm_predict_create_with', ['number', 'number'], [callbacks_ptr, clock_ptr]);
    };

    window.colyseus_gm_predict_free = function(predict_id) {
        _callV('colyseus_gm_predict_free', ['number'], [predict_id]);
    };

    window.colyseus_gm_predict_tick = function(predict_id, now) {
        return _callN('colyseus_gm_predict_tick', ['number', 'number'], [predict_id, now]);
    };

    window.colyseus_gm_predict_attach = function(predict_id, instance, config_json) {
        return _callN('colyseus_gm_predict_attach', ['number', 'number', 'string'], [predict_id, instance, config_json]);
    };

    window.colyseus_gm_predict_attach_all = function(predict_id, state_instance, spec_json) {
        return _callN('colyseus_gm_predict_attach_all', ['number', 'number', 'string'], [predict_id, state_instance, spec_json]);
    };

    window.colyseus_gm_predict_attach_reckon = function(predict_id, instance, spec_json) {
        return _callN('colyseus_gm_predict_attach_reckon', ['number', 'number', 'string'], [predict_id, instance, spec_json]);
    };

    window.colyseus_gm_predict_attach_all_reckon = function(predict_id, state_instance, spec_json) {
        return _callN('colyseus_gm_predict_attach_all_reckon', ['number', 'number', 'string'], [predict_id, state_instance, spec_json]);
    };

    window.colyseus_gm_predict_detach = function(predict_id, instance) {
        _callV('colyseus_gm_predict_detach', ['number', 'number'], [predict_id, instance]);
    };

    window.colyseus_gm_predict_value = function(predict_id, instance, field) {
        return _callN('colyseus_gm_predict_value', ['number', 'number', 'string'], [predict_id, instance, field]);
    };

    window.colyseus_gm_predict_value_at = function(predict_id, instance, field, time) {
        return _callN('colyseus_gm_predict_value_at', ['number', 'number', 'string', 'number'], [predict_id, instance, field, time]);
    };

    window.colyseus_gm_predict_reconciler = function(predict_id, truth_instance, input_h, spec_json) {
        return _callN('colyseus_gm_predict_reconciler', ['number', 'number', 'number', 'string'], [predict_id, truth_instance, input_h, spec_json]);
    };

    window.colyseus_gm_sim_begin = function(predict_id) {
        return _callN('colyseus_gm_sim_begin', ['number'], [predict_id]);
    };

    window.colyseus_gm_sim_part = function(name, instance) {
        return _callN('colyseus_gm_sim_part', ['string', 'number'], [name, instance]);
    };

    window.colyseus_gm_sim_create = function(input_h, smoothing, snap, step_ms, sub_steps) {
        return _callN('colyseus_gm_sim_create', ['number', 'number', 'number', 'number', 'number'], [input_h, smoothing, snap, step_ms, sub_steps]);
    };

    window.colyseus_gm_sim_part_mirror = function(recon_id, name) {
        return _callN('colyseus_gm_sim_part_mirror', ['number', 'string'], [recon_id, name]);
    };

    window.colyseus_gm_recon_free = function(recon_id) {
        _callV('colyseus_gm_recon_free', ['number'], [recon_id]);
    };

    window.colyseus_gm_recon_pump_begin = function(recon_id) {
        return _callN('colyseus_gm_recon_pump_begin', ['number'], [recon_id]);
    };

    window.colyseus_gm_recon_pump_next = function(recon_id) {
        return _callN('colyseus_gm_recon_pump_next', ['number'], [recon_id]);
    };

    window.colyseus_gm_recon_pump_commit = function(recon_id) {
        _callV('colyseus_gm_recon_pump_commit', ['number'], [recon_id]);
    };

    window.colyseus_gm_recon_pump_end = function(recon_id) {
        _callV('colyseus_gm_recon_pump_end', ['number'], [recon_id]);
    };

    window.colyseus_gm_step_ctx = function(which) {
        return _callN('colyseus_gm_step_ctx', ['number'], [which]);
    };

    window.colyseus_gm_step_cmd = function(field) {
        return _callN('colyseus_gm_step_cmd', ['string'], [field]);
    };

    window.colyseus_gm_recon_value = function(recon_id, field_or_posekey) {
        return _callN('colyseus_gm_recon_value', ['number', 'string'], [recon_id, field_or_posekey]);
    };

    window.colyseus_gm_recon_state = function(recon_id) {
        return _callN('colyseus_gm_recon_state', ['number'], [recon_id]);
    };

    window.colyseus_gm_recon_stat = function(recon_id, which) {
        return _callN('colyseus_gm_recon_stat', ['number', 'number'], [recon_id, which]);
    };

    window.colyseus_gm_recon_last_correction = function(recon_id, field) {
        return _callN('colyseus_gm_recon_last_correction', ['number', 'string'], [recon_id, field]);
    };

    window.colyseus_gm_recon_reset = function(recon_id) {
        _callV('colyseus_gm_recon_reset', ['number'], [recon_id]);
    };

    window.colyseus_gm_mirror_set = function(instance, field, value) {
        return _callN('colyseus_gm_mirror_set', ['number', 'string', 'number'], [instance, field, value]);
    };

    window.colyseus_gm_mirror_get = function(instance, field) {
        return _callN('colyseus_gm_mirror_get', ['number', 'string'], [instance, field]);
    };

    window.colyseus_gm_step_memo_peek = function(key) {
        return _callN('colyseus_gm_step_memo_peek', ['string'], [key]);
    };

    window.colyseus_gm_step_memo_store = function(key, value) {
        return _callN('colyseus_gm_step_memo_store', ['string', 'number'], [key, value]);
    };

    window.colyseus_gm_events_create = function(clock_h, grace_ticks, ttl_ms, cooldown_ms) {
        return _callN('colyseus_gm_events_create', ['number', 'number', 'number', 'number'], [clock_h, grace_ticks, ttl_ms, cooldown_ms]);
    };

    window.colyseus_gm_events_free = function(channel_id) {
        _callV('colyseus_gm_events_free', ['number'], [channel_id]);
    };

    window.colyseus_gm_predict_drive_events = function(predict_id, channel_id) {
        _callV('colyseus_gm_predict_drive_events', ['number', 'number'], [predict_id, channel_id]);
    };

    window.colyseus_gm_events_predict = function(channel_id, key) {
        return _callN('colyseus_gm_events_predict', ['number', 'string'], [channel_id, key]);
    };

    window.colyseus_gm_step_predict = function(channel_id, key) {
        _callV('colyseus_gm_step_predict', ['number', 'string'], [channel_id, key]);
    };

    window.colyseus_gm_events_confirm = function(channel_id, key) {
        return _callN('colyseus_gm_events_confirm', ['number', 'string'], [channel_id, key]);
    };

    window.colyseus_gm_events_reject = function(channel_id, key) {
        return _callN('colyseus_gm_events_reject', ['number', 'string'], [channel_id, key]);
    };

    window.colyseus_gm_events_has = function(channel_id, key) {
        return _callN('colyseus_gm_events_has', ['number', 'string'], [channel_id, key]);
    };

    window.colyseus_gm_events_pending = function(channel_id) {
        return _callN('colyseus_gm_events_pending', ['number'], [channel_id]);
    };

    window.colyseus_gm_events_clear = function(channel_id) {
        _callV('colyseus_gm_events_clear', ['number'], [channel_id]);
    };

    window.colyseus_gm_spawns_create = function(clock_h, spec_json) {
        return _callN('colyseus_gm_spawns_create', ['number', 'string'], [clock_h, spec_json]);
    };

    window.colyseus_gm_spawns_free = function(spawns_id) {
        _callV('colyseus_gm_spawns_free', ['number'], [spawns_id]);
    };

    window.colyseus_gm_predict_bind_spawns = function(predict_id, spawns_id, state_instance, collection) {
        _callV('colyseus_gm_predict_bind_spawns', ['number', 'number', 'number', 'string'], [predict_id, spawns_id, state_instance, collection]);
    };

    window.colyseus_gm_spawns_spawn_set = function(spawns_id, field, value) {
        return _callN('colyseus_gm_spawns_spawn_set', ['number', 'string', 'number'], [spawns_id, field, value]);
    };

    window.colyseus_gm_spawns_spawn = function(spawns_id) {
        return _callN('colyseus_gm_spawns_spawn', ['number'], [spawns_id]);
    };

    window.colyseus_gm_spawns_cancel = function(spawns_id, id) {
        _callV('colyseus_gm_spawns_cancel', ['number', 'number'], [spawns_id, id]);
    };

    window.colyseus_gm_spawns_accept = function(spawns_id, id) {
        _callV('colyseus_gm_spawns_accept', ['number', 'number'], [spawns_id, id]);
    };

    window.colyseus_gm_spawns_size = function(spawns_id) {
        return _callN('colyseus_gm_spawns_size', ['number'], [spawns_id]);
    };

    window.colyseus_gm_spawns_alive = function(spawns_id, id) {
        return _callN('colyseus_gm_spawns_alive', ['number', 'number'], [spawns_id, id]);
    };

    window.colyseus_gm_spawns_handle_add = function(spawns_id, server_instance) {
        _callV('colyseus_gm_spawns_handle_add', ['number', 'number'], [spawns_id, server_instance]);
    };

    window.colyseus_gm_spawns_handle_remove = function(spawns_id, server_instance) {
        _callV('colyseus_gm_spawns_handle_remove', ['number', 'number'], [spawns_id, server_instance]);
    };

    window.colyseus_gm_spawns_tick = function(spawns_id, now) {
        _callV('colyseus_gm_spawns_tick', ['number', 'number'], [spawns_id, now]);
    };

    window.colyseus_gm_spawns_iter_begin = function(spawns_id) {
        return _callN('colyseus_gm_spawns_iter_begin', ['number'], [spawns_id]);
    };

    window.colyseus_gm_spawns_iter_next = function(spawns_id) {
        return _callN('colyseus_gm_spawns_iter_next', ['number'], [spawns_id]);
    };

    window.colyseus_gm_spawns_entry_stat = function(spawns_id, which) {
        return _callN('colyseus_gm_spawns_entry_stat', ['number', 'number'], [spawns_id, which]);
    };

    window.colyseus_gm_spawns_entry_value = function(spawns_id, field) {
        return _callN('colyseus_gm_spawns_entry_value', ['number', 'string'], [spawns_id, field]);
    };

    window.colyseus_gm_spawns_seek = function(spawns_id, id) {
        return _callN('colyseus_gm_spawns_seek', ['number', 'number'], [spawns_id, id]);
    };

    window.colyseus_gm_netdelay_set = function(room_ref, delay_ms, jitter_ms) {
        _callV('colyseus_gm_netdelay_set', ['number', 'number', 'number'], [room_ref, delay_ms, jitter_ms]);
    };

    window.colyseus_gm_netdelay_pump = function() {
        _callV('colyseus_gm_netdelay_pump', [], []);
    };

    window.colyseus_gm_netdelay_in_flight = function() {
        return _callN('colyseus_gm_netdelay_in_flight', [], []);
    };

    window.colyseus_gm_netdelay_drop = function(room_ref) {
        _callV('colyseus_gm_netdelay_drop', ['number'], [room_ref]);
    };

    // === GENERATED BINDINGS END ===

})();

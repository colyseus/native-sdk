// =============================================================================
// Test Helpers — utilities for HTTP API tests
// =============================================================================

/// Drain all pending events from the queue (call in beforeEach for isolation)
function test_drain_events() {
    var _safety = 0;
    while (colyseus_poll_event() != COLYSEUS_EVENT_NONE) {
        _safety++;
        if (_safety > 1000) break;
    }
}

/// Poll colyseus_process() in a loop until _ctx.done is true or timeout.
/// Use for integration tests that need to wait for real async HTTP responses.
/// @param {Struct} _ctx  Struct with a .done field (set to true by the callback)
/// @param {Real} _timeout_ms  Maximum time to wait in milliseconds
/// @returns {Bool} true if _ctx.done became true before timeout
function test_poll_until(_ctx, _timeout_ms) {
    var _start = current_time;
    while (!_ctx.done && (current_time - _start < _timeout_ms)) {
        colyseus_process();
    }
    return _ctx.done;
}

/// Register a callback directly in the HTTP handlers map at a known request ID.
/// Used by unit tests to bypass the native HTTP request and test dispatch only.
/// @param {Real} _request_id  Known request ID (use 9000+ to avoid collisions)
/// @param {Function} _callback  callback(err, data)
function test_register_http_handler(_request_id, _callback) {
    ds_map_set(global.__colyseus_http_handlers, _request_id, _callback);
}

/// Check if a handler exists in the HTTP handlers map.
/// @param {Real} _request_id
/// @returns {Bool}
function test_http_handler_exists(_request_id) {
    return ds_map_exists(global.__colyseus_http_handlers, _request_id);
}

/// Get the current number of registered HTTP handlers.
/// @returns {Real}
function test_http_handler_count() {
    return ds_map_size(global.__colyseus_http_handlers);
}

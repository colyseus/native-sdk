const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
});

var success_called: c_int = 0;
var error_called: c_int = 0;

fn onHttpSuccess(response: [*c]const c.colyseus_http_response_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = response;
    _ = userdata;
    success_called = 1;
}

fn onHttpError(err: [*c]const c.colyseus_http_error_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = err;
    _ = userdata;
    error_called = 1;
}

test "http: request to offline service" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "9999"); // Non-existent port

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const http = c.colyseus_client_get_http(client);

    c.colyseus_http_get(http, "/test", onHttpSuccess, onHttpError, null);

    // Wait for async request
    std.Thread.sleep(2 * std.time.ns_per_s);

    try testing.expectEqual(@as(c_int, 1), error_called);
}

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/auth/auth.h");
    @cInclude("string.h");
});

var auth_change_called: c_int = 0;
var received_token: ?[*:0]u8 = null;

fn onAuthChange(data: [*c]const c.colyseus_auth_data_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    auth_change_called += 1;

    if (data.*.token != null) {
        if (received_token) |old_token| {
            std.c.free(old_token);
        }
        received_token = @ptrCast(c.strdup(data.*.token));
    } else {
        if (received_token) |old_token| {
            std.c.free(old_token);
        }
        received_token = null;
    }
}

test "auth: token operations" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const auth = c.colyseus_client_get_auth(client);

    // Test onChange callback
    c.colyseus_auth_on_change(auth, onAuthChange, null);
    try testing.expect(auth_change_called > 0);

    // Test set token
    auth_change_called = 0;
    c.colyseus_auth_set_token(auth, "test_token_123");

    const token = c.colyseus_auth_get_token(auth);
    try testing.expect(token != null);
    try testing.expectEqualStrings("test_token_123", std.mem.span(token));

    // Test token persistence
    c.colyseus_auth_signout(auth);
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Cleanup
    if (received_token) |token_ptr| {
        std.c.free(token_ptr);
        received_token = null;
    }
}

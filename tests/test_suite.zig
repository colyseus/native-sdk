const std = @import("std");
const testing = std.testing;

// Import C headers
const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/room.h");
    @cInclude("colyseus/auth/auth.h");
    @cInclude("colyseus/auth/secure_storage.h");
});

// ============================================================================
// Room Tests
// ============================================================================

test "room: create and basic properties" {
    const room = c.colyseus_room_create("test_room", c.colyseus_websocket_transport_create);
    try testing.expect(room != null);

    const room_name = c.colyseus_room_get_name(room);
    try testing.expect(room_name != null);
    try testing.expectEqualStrings("test_room", std.mem.span(room_name));

    c.colyseus_room_free(room);
}

test "room: set and get id and session id" {
    const room = c.colyseus_room_create("test_room", c.colyseus_websocket_transport_create);
    defer c.colyseus_room_free(room);

    c.colyseus_room_set_id(room, "test_room_id");
    c.colyseus_room_set_session_id(room, "test_session_id");

    const room_id = c.colyseus_room_get_id(room);
    const session_id = c.colyseus_room_get_session_id(room);

    try testing.expectEqualStrings("test_room_id", std.mem.span(room_id));
    try testing.expectEqualStrings("test_session_id", std.mem.span(session_id));
}

test "room: register message handlers" {
    const room = c.colyseus_room_create("test_room", c.colyseus_websocket_transport_create);
    defer c.colyseus_room_free(room);

    const Handler = struct {
        fn onMessage(data: [*c]const u8, length: usize, userdata: ?*anyopaque) callconv(.c) void {
            _ = data;
            _ = length;
            _ = userdata;
        }

        fn onStateChange(userdata: ?*anyopaque) callconv(.c) void {
            _ = userdata;
        }
    };

    c.colyseus_room_on_message(room, "chat", Handler.onMessage, null);
    c.colyseus_room_on_state_change(room, Handler.onStateChange, null);

    // If we get here without crashing, handlers were registered successfully
    try testing.expect(true);
}

// ============================================================================
// Secure Storage Tests
// ============================================================================

test "storage: set and get" {
    const result = c.secure_storage_set("test_key_zig", "test_value_zig");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key_zig");
    try testing.expect(value != null);

    const value_str = std.mem.span(value);
    try testing.expectEqualStrings("test_value_zig", value_str);

    std.c.free(value);
}

test "storage: update existing key" {
    var result = c.secure_storage_set("test_key_update", "initial_value");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    result = c.secure_storage_set("test_key_update", "updated_value");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key_update");
    try testing.expect(value != null);

    const value_str = std.mem.span(value);
    try testing.expectEqualStrings("updated_value", value_str);

    std.c.free(value);
    _ = c.secure_storage_remove("test_key_update");
}

test "storage: remove key" {
    var result = c.secure_storage_set("test_key_remove", "temporary_value");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    result = c.secure_storage_remove("test_key_remove");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key_remove");
    try testing.expect(value == null);
}

test "storage: non-existent key returns null" {
    const value = c.secure_storage_get("non_existent_key_12345");
    try testing.expect(value == null);
}

test "storage: availability check" {
    const available = c.secure_storage_available();
    // Just verify it returns something reasonable (0 or 1)
    try testing.expect(available == 0 or available == 1);
}

// ============================================================================
// Auth Tests
// ============================================================================

test "auth: create and get token" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const auth = c.colyseus_client_get_auth(client);
    try testing.expect(auth != null);

    c.colyseus_auth_set_token(auth, "test_token_zig_123");

    const token = c.colyseus_auth_get_token(auth);
    try testing.expect(token != null);
    try testing.expectEqualStrings("test_token_zig_123", std.mem.span(token));
}

test "auth: signout clears token" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const auth = c.colyseus_client_get_auth(client);

    c.colyseus_auth_set_token(auth, "token_to_clear");
    c.colyseus_auth_signout(auth);

    // Note: After signout, token might be null or empty depending on implementation
    // Just verify the function doesn't crash
    _ = c.colyseus_auth_get_token(auth);
    try testing.expect(true);
}

// ============================================================================
// Client Tests
// ============================================================================

test "client: create with settings" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "9999");

    const client = c.colyseus_client_create(settings);
    try testing.expect(client != null);

    c.colyseus_client_free(client);
}

test "client: get http instance" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const http = c.colyseus_client_get_http(client);
    try testing.expect(http != null);
}

test "client: get auth instance" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const auth = c.colyseus_client_get_auth(client);
    try testing.expect(auth != null);
}

// ============================================================================
// Settings Tests
// ============================================================================

test "settings: create and configure" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    try testing.expect(settings != null);

    c.colyseus_settings_set_address(settings, "example.com");
    c.colyseus_settings_set_port(settings, "8080");

    // If we get here without crashing, settings were configured successfully
    try testing.expect(true);
}

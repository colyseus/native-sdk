const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("string.h");
});

const TEST_SERVER = "localhost";
const TEST_PORT = "2567";
const TIMEOUT_SECONDS = 10;

var test_passed: c_int = 0;
var test_failed: c_int = 0;
var joined: c_int = 0;
var state_received: c_int = 0;
var message_received: c_int = 0;

fn onJoin(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    joined = 1;
}

fn onStateChange(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    state_received = 1;
}

fn onMessageAny(data: [*c]const u8, length: usize, userdata: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = length;
    _ = userdata;
    message_received = 1;
}

fn onRoomError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = message;
    _ = userdata;
    test_failed = 1;
}

fn onLeave(code: c_int, reason: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = reason;
    _ = userdata;
}

fn onError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = message;
    _ = userdata;
    test_failed = 1;
}

fn onRoomSuccess(room: [*c]c.colyseus_room_t, userdata: ?*anyopaque) callconv(.c) void {
    c.colyseus_room_on_join(room, onJoin, null);
    c.colyseus_room_on_state_change(room, onStateChange, null);
    c.colyseus_room_on_message_any(room, onMessageAny, null);
    c.colyseus_room_on_error(room, onRoomError, null);
    c.colyseus_room_on_leave(room, onLeave, null);

    const room_ptr: *?[*c]c.colyseus_room_t = @ptrCast(@alignCast(userdata));
    room_ptr.* = room;

    test_passed = 1;
}

test "integration: full connection flow" {
    // Reset state
    test_passed = 0;
    test_failed = 0;
    joined = 0;
    state_received = 0;
    message_received = 0;

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    if (client == null) {
        return error.ClientCreationFailed;
    }

    var room: ?[*c]c.colyseus_room_t = null;

    c.colyseus_client_join_or_create(
        client,
        "my_room",
        "{}",
        onRoomSuccess,
        onError,
        &room,
    );

    std.Thread.sleep(50 * std.time.ns_per_ms);
    // try testing.expect(false);

    // Should have joined by now
    try testing.expect(joined == 1);

    // Test sending a message if connected
    const test_msg = [_]u8{0x80};
    c.colyseus_room_send(room.?, "test", &test_msg, test_msg.len);

    std.Thread.sleep(50 * std.time.ns_per_ms);

    c.colyseus_room_leave(room.?, true);
    defer c.colyseus_room_free(room.?);

    try testing.expect(test_passed == 1);

    std.Thread.sleep(100 * std.time.ns_per_ms);
}

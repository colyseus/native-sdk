const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("string.h");
});

var message_received: c_int = 0;
var state_changed: c_int = 0;

fn onMessageString(data: [*c]const u8, length: usize, userdata: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = length;
    _ = userdata;
    message_received += 1;
}

fn onStateChange(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    state_changed += 1;
}

test "room: basic operations" {
    // Create a room
    const room = c.colyseus_room_create("test_room", c.colyseus_websocket_transport_create);
    defer c.colyseus_room_free(room);

    try testing.expect(room != null);

    // Test room properties
    const room_name = c.colyseus_room_get_name(room);
    try testing.expect(room_name != null);
    try testing.expectEqualStrings("test_room", std.mem.span(room_name));

    // Test setting room ID and session ID
    c.colyseus_room_set_id(room, "test_room_id");
    c.colyseus_room_set_session_id(room, "test_session_id");

    const room_id = c.colyseus_room_get_id(room);
    const session_id = c.colyseus_room_get_session_id(room);

    try testing.expectEqualStrings("test_room_id", std.mem.span(room_id));
    try testing.expectEqualStrings("test_session_id", std.mem.span(session_id));

    // Test message handler registration
    c.colyseus_room_on_message(room, "chat", onMessageString, null);
    c.colyseus_room_on_state_change(room, onStateChange, null);
}

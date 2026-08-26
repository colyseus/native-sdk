const std = @import("std");
const testing = std.testing;

// ============================================================================
// Decoding into a REFLECTION-built vtable (requires server)
//
// Every test elsewhere decodes into a codegen'd struct. Bindings that have no
// codegen — Godot's GDScript, the Swift package — take the other path: the
// handshake's reflection builds a dynamic vtable and each instance stores its
// fields in a hash instead of at struct offsets. These check that the two
// paths agree, because a divergence there is invisible to the rest of the
// suite.
// ============================================================================

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/schema.h");
    @cInclude("colyseus/schema/dynamic_schema.h");
    @cInclude("string.h");
});

const TEST_SERVER = "localhost";
const TEST_PORT = "2567";

// Suites run in parallel against one server, and TestRoom sets no maxClients.
const PRIVATE_ROOM = "{\"private\":true}";

var joined = false;
var joined_room: ?*c.colyseus_room_t = null;

fn onJoin(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    joined = true;
}

fn onRoom(room: ?*c.colyseus_room_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    joined_room = room;
    c.colyseus_room_on_join(room, onJoin, null);
}

fn onError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    std.debug.print("matchmaking failed ({d}): {s}\n", .{ code, message });
}

fn settle(ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

fn waitFor(condition: *const fn () bool, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 20) {
        if (condition()) return true;
        settle(20);
    }
    return condition();
}

fn hasJoined() bool {
    return joined;
}

/// The dynamic value behind `name`, or null when the field was never decoded.
fn field(instance: ?*anyopaque, name: [*c]const u8) ?*c.colyseus_dynamic_value_t {
    const dynamic: ?*c.colyseus_dynamic_schema_t = @ptrCast(@alignCast(instance));
    return c.colyseus_dynamic_schema_get_by_name(dynamic, name);
}

test "reflection decode: one push produces one array entry" {
    joined = false;
    joined_room = null;

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    // No colyseus_room_set_state_type: the handshake builds the vtable.
    c.colyseus_client_create_room(client, "test_room", PRIVATE_ROOM, onRoom, onError, null);

    try testing.expect(waitFor(hasJoined, 5000));
    const room = joined_room.?;
    defer c.colyseus_room_free(room);

    settle(300);

    const session_id = c.colyseus_room_get_session_id(room);
    const state = c.colyseus_room_get_state(room);
    try testing.expect(state != null);

    const players = field(state, "players").?.data.map;
    const me = c.colyseus_map_schema_get(players, session_id);
    try testing.expect(me != null);

    // Baseline: TestRoom seeds one item on join.
    const before = field(me, "items").?.data.array.*.count;

    const message = c.colyseus_message_map_create();
    defer c.colyseus_message_free(message);
    c.colyseus_message_map_put_str(message, "name", "sword");
    c.colyseus_room_send(room, "add_item", message);

    settle(800);

    const after = field(me, "items").?.data.array.*.count;
    try testing.expectEqual(before + 1, after);

    c.colyseus_room_leave(room, true);
    settle(200);
}

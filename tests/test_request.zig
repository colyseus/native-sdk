const std = @import("std");
const testing = std.testing;

// ============================================================================
// room.request() against a live server — the four ROOM_RESPONSE outcomes plus
// the two the wire never carries (no handler, cancelled).
//
// Drives colyseus_room_request_encoded_reply(), the shape every language
// binding uses: msgpack in, msgpack out, decoded by the binding.
//
// Fixtures: example-server TestRoom's `request_*` handlers.
// ============================================================================

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/room.h");
    @cInclude("colyseus/messages.h");
});

const TEST_SERVER = "localhost";
const TEST_PORT = "2567";

/// One request's answer, captured off the transport thread.
const Reply = struct {
    replied: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: bool = false,
    faulted: bool = false,
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn wait(self: *Reply, seconds: u64) bool {
        var waited: u64 = 0;
        const step = 10 * std.time.ns_per_ms;
        while (waited < seconds * std.time.ns_per_s) : (waited += step) {
            if (self.replied.load(.acquire)) return true;
            std.Thread.sleep(step);
        }
        return self.replied.load(.acquire);
    }

    fn reader(self: *Reply) ?*c.colyseus_message_reader_t {
        if (self.len == 0) return null;
        return c.colyseus_message_reader_create(&self.bytes, self.len);
    }
};

fn onReply(ok: bool, data: [*c]const u8, length: usize, err: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const reply: *Reply = @ptrCast(@alignCast(userdata.?));
    reply.ok = ok;
    reply.faulted = (err != null);
    reply.len = 0;
    if (data != null and length > 0 and length <= reply.bytes.len) {
        @memcpy(reply.bytes[0..length], data[0..length]);
        reply.len = length;
    }
    reply.replied.store(true, .release);
}

// ─── connection ─────────────────────────────────────────────────────────────

var joined = std.atomic.Value(bool).init(false);
var join_failed = std.atomic.Value(bool).init(false);

fn onJoin(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    joined.store(true, .release);
}

fn onRoomSuccess(room: [*c]c.colyseus_room_t, userdata: ?*anyopaque) callconv(.c) void {
    c.colyseus_room_on_join(room, onJoin, null);
    const slot: *?[*c]c.colyseus_room_t = @ptrCast(@alignCast(userdata));
    slot.* = room;
}

fn onMatchmakeError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = message;
    _ = userdata;
    join_failed.store(true, .release);
}

const Session = struct {
    client: ?*c.colyseus_client_t,
    settings: ?*c.colyseus_settings_t,
    room: [*c]c.colyseus_room_t,

    fn close(self: *Session) void {
        c.colyseus_room_leave(self.room, true);
        std.Thread.sleep(150 * std.time.ns_per_ms);
        c.colyseus_room_free(self.room);
        c.colyseus_client_free(self.client);
        c.colyseus_settings_free(self.settings);
    }
};

/// A private room per test: the suites run in parallel against one server.
fn connect() !Session {
    joined.store(false, .release);
    join_failed.store(false, .release);

    const settings = c.colyseus_settings_create();
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);
    const client = c.colyseus_client_create(settings) orelse return error.ClientCreationFailed;

    var room: ?[*c]c.colyseus_room_t = null;
    c.colyseus_client_create_room(client, "test_room", "{\"private\":true}", onRoomSuccess, onMatchmakeError, &room);

    var waited: u64 = 0;
    const step = 10 * std.time.ns_per_ms;
    while (waited < 10 * std.time.ns_per_s) : (waited += step) {
        if (joined.load(.acquire) or join_failed.load(.acquire)) break;
        std.Thread.sleep(step);
    }
    if (!joined.load(.acquire)) return error.SkipZigTest;

    return .{ .client = client, .settings = settings, .room = room.? };
}

// ─── the outcomes ───────────────────────────────────────────────────────────

test "request: OK carries the handler's return value" {
    var session = try connect();
    defer session.close();

    // {"a":1,"b":2} — hand-encoded, because that is what a binding hands us.
    const payload = [_]u8{ 0x82, 0xa1, 'a', 0x01, 0xa1, 'b', 0x02 };
    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_sum", &payload, payload.len, onReply, &reply);

    try testing.expect(reply.wait(5));
    try testing.expect(reply.ok);
    try testing.expect(!reply.faulted);
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, reply.bytes[0..reply.len]);
}

test "request: the reply is raw msgpack, so nesting survives" {
    var session = try connect();
    defer session.close();

    // {"nested":{"list":[1,2]}}. Compared by VALUE, not bytes: the server
    // re-encodes what it echoes, and msgpack spells the same map more than one
    // way (fixmap here, map16 back).
    const payload = [_]u8{
        0x81, 0xa6, 'n', 'e', 's', 't', 'e', 'd',
        0x81, 0xa4, 'l', 'i', 's', 't', 0x92, 0x01, 0x02,
    };
    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_echo", &payload, payload.len, onReply, &reply);

    try testing.expect(reply.wait(5));
    try testing.expect(reply.ok);

    const r = reply.reader() orelse return error.EmptyReply;
    defer c.colyseus_message_reader_free(r);
    const nested = c.colyseus_message_reader_map_get(r, "nested") orelse return error.NoNestedMap;
    defer c.colyseus_message_reader_free(nested);
    const list = c.colyseus_message_reader_map_get(nested, "list") orelse return error.NoList;
    defer c.colyseus_message_reader_free(list);

    try testing.expect(c.colyseus_message_reader_is_array(list));
    try testing.expectEqual(@as(usize, 2), c.colyseus_message_reader_get_array_size(list));
    const first = c.colyseus_message_reader_get_array_element(list, 0) orelse return error.NoElement;
    defer c.colyseus_message_reader_free(first);
    try testing.expectEqual(@as(i64, 1), c.colyseus_message_reader_get_int(first));
}

test "request: a side-effect-only handler replies OK with nothing" {
    var session = try connect();
    defer session.close();

    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_ack", null, 0, onReply, &reply);

    try testing.expect(reply.wait(5));
    try testing.expect(reply.ok);
    // Empty, not a msgpack nil: a binding must not report a null reply value
    // where the server sent no value at all.
    try testing.expectEqual(@as(usize, 0), reply.len);
}

test "request: a rejection is not a fault, and keeps the authored reason" {
    var session = try connect();
    defer session.close();

    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_deny", null, 0, onReply, &reply);

    try testing.expect(reply.wait(5));
    try testing.expect(!reply.ok);
    // The distinction the whole outcome model exists for: a deliberate reject
    // is NOT faulted, so a binding can surface the reason verbatim instead of
    // an error string.
    try testing.expect(!reply.faulted);

    const r = reply.reader() orelse return error.NoReason;
    defer c.colyseus_message_reader_free(r);
    var code: i64 = 0;
    try testing.expect(c.colyseus_message_reader_map_get_int(r, "code", &code));
    try testing.expectEqual(@as(i64, 403), code);
}

test "request: a thrown handler faults, and cannot pose as a rejection" {
    var session = try connect();
    defer session.close();

    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_boom", null, 0, onReply, &reply);

    try testing.expect(reply.wait(5));
    try testing.expect(!reply.ok);
    try testing.expect(reply.faulted);

    // Sanitized { name, message } rather than a raw reason.
    const r = reply.reader() orelse return error.NoErrorPayload;
    defer c.colyseus_message_reader_free(r);
    var name: [*c]const u8 = undefined;
    var name_len: usize = 0;
    try testing.expect(c.colyseus_message_reader_map_get_str(r, "name", &name, &name_len));
    try testing.expect(name_len > 0);
}

test "request: an unregistered type faults rather than hanging" {
    var session = try connect();
    defer session.close();

    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "no_such_handler", null, 0, onReply, &reply);

    // The failure this guards is a caller waiting out its whole timeout for a
    // reply the server was never going to send.
    try testing.expect(reply.wait(5));
    try testing.expect(!reply.ok);
    try testing.expect(reply.faulted);
}

test "request: cancelling drops the reply, which is what a timeout is built on" {
    var session = try connect();
    defer session.close();

    // Answers in ~1.5s; cancelled well before that.
    const payload = [_]u8{ 0x81, 0xa2, 'm', 's', 0xcd, 0x05, 0xdc }; // {"ms":1500}
    var reply = Reply{};
    const id = c.colyseus_room_request_encoded_reply(session.room, "request_slow", &payload, payload.len, onReply, &reply);
    c.colyseus_room_cancel_request(session.room, id);

    try testing.expect(!reply.wait(3));
}

test "request: a close answers everything still in flight" {
    const session = try connect();

    const payload = [_]u8{ 0x81, 0xa2, 'm', 's', 0xcd, 0x13, 0x88 }; // {"ms":5000}
    var reply = Reply{};
    _ = c.colyseus_room_request_encoded_reply(session.room, "request_slow", &payload, payload.len, onReply, &reply);

    // Leaving must not strand the caller waiting for a reply that can no
    // longer arrive.
    c.colyseus_room_leave(session.room, true);
    try testing.expect(reply.wait(5));
    try testing.expect(!reply.ok);
    try testing.expect(reply.faulted);

    std.Thread.sleep(150 * std.time.ns_per_ms);
    c.colyseus_room_free(session.room);
    c.colyseus_client_free(session.client);
    c.colyseus_settings_free(session.settings);
}

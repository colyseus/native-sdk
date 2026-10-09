// colyseus_client_consume_seat_reservation[_json]() against example-server
// (localhost:2567), whose POST /reserve_seat returns what the server's
// matchMaker.joinOrCreate() reserved — the seat a backend hands its client.
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const ms = std.time.ns_per_ms;

// Suites run in parallel against one server: a private room keeps this one's
// callbacks free of other clients.
const RESERVE_BODY = "{\"roomName\":\"test_room\",\"options\":{\"private\":true}}";

// ─── recorder ───────────────────────────────────────────────────────────────

const S = struct {
    var room: [*c]c.colyseus_room_t = null;
    var matched: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var joins: std.atomic.Value(u32) = .init(0);
    var leaves: std.atomic.Value(u32) = .init(0);
    var fail_message: [128]u8 = undefined;
    var fail_len: usize = 0;

    fn reset() void {
        room = null;
        inline for (.{ &matched, &failed, &joins, &leaves }) |v| v.store(0, .seq_cst);
        fail_len = 0;
    }

    fn onRoom(r: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        room = r;
        c.colyseus_room_on_join(r, onJoin, null);
        c.colyseus_room_on_leave(r, onLeave, null);
        _ = matched.fetchAdd(1, .seq_cst);
    }
    fn onFail(_: c_int, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        const text = std.mem.span(message);
        fail_len = @min(text.len, fail_message.len);
        @memcpy(fail_message[0..fail_len], text[0..fail_len]);
        _ = failed.fetchAdd(1, .seq_cst);
    }
    fn onJoin(_: ?*anyopaque) callconv(.c) void {
        _ = joins.fetchAdd(1, .seq_cst);
    }
    fn onLeave(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        _ = leaves.fetchAdd(1, .seq_cst);
    }

    fn joined() bool {
        return joins.load(.seq_cst) >= 1;
    }
    fn left() bool {
        return leaves.load(.seq_cst) >= 1;
    }
    fn hasFailed() bool {
        return failed.load(.seq_cst) >= 1;
    }
    fn failMessage() []const u8 {
        return fail_message[0..fail_len];
    }
};

fn pollUntil(comptime cond: fn () bool, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        c.colyseus_poll();
        if (cond()) return true;
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(5 * ms);
    }
}

fn newClient(port: [*c]const u8) ![*c]c.colyseus_client_t {
    const settings = c.colyseus_settings_create();
    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, port);
    const client = c.colyseus_client_create(settings);
    if (client == null) return error.OutOfMemory;
    return client;
}

fn freeClient(client: [*c]c.colyseus_client_t) void {
    const settings = client.*.settings;
    c.colyseus_client_free(client);
    c.colyseus_settings_free(settings);
}

fn leaveAndFree() !void {
    c.colyseus_room_leave(S.room, true);
    try testing.expect(pollUntil(S.left, 5000));
    c.colyseus_room_free(S.room);
    S.room = null;
}

// ─── fetching a reservation ─────────────────────────────────────────────────

const Fetched = struct {
    var body: ?[*c]u8 = null;

    fn onOk(response: [*c]const c.colyseus_http_response_t, _: ?*anyopaque) callconv(.c) void {
        body = c.strdup(response.*.body);
    }
    fn onErr(_: [*c]const c.colyseus_http_error_t, _: ?*anyopaque) callconv(.c) void {}
};

/// A fresh seat in a private test_room, as JSON. Caller frees.
fn reserveSeat(client: [*c]c.colyseus_client_t) ![*c]u8 {
    Fetched.body = null;
    // blocks; the callbacks run before it returns
    c.colyseus_http_post(c.colyseus_client_get_http(client), "/reserve_seat", RESERVE_BODY, Fetched.onOk, Fetched.onErr, null);
    return Fetched.body orelse error.ReserveSeatFailed;
}

const Reservation = struct {
    name: []const u8,
    sessionId: []const u8,
    roomId: []const u8,
    processId: []const u8,
};

fn parseReservation(json: [*c]const u8) !std.json.Parsed(Reservation) {
    return std.json.parseFromSlice(Reservation, testing.allocator, std.mem.span(json), .{ .ignore_unknown_fields = true });
}

// ─── tests ──────────────────────────────────────────────────────────────────

test "seat reservation: JSON form joins the reserved room, delivered inside colyseus_poll" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    S.reset();

    const client = try newClient("2567");
    defer freeClient(client);

    const json = try reserveSeat(client);
    defer c.free(json);
    const seat = try parseReservation(json);
    defer seat.deinit();

    c.colyseus_client_consume_seat_reservation_json(client, json, S.onRoom, S.onFail, null);
    // like every other matchmaking call: nothing fires before it returns
    try testing.expectEqual(@as(u32, 0), S.matched.load(.seq_cst));

    try testing.expect(pollUntil(S.joined, 10_000));
    try testing.expectEqual(@as(u32, 0), S.failed.load(.seq_cst));
    try testing.expectEqualStrings(seat.value.sessionId, std.mem.span(c.colyseus_room_get_session_id(S.room)));
    try testing.expectEqualStrings(seat.value.roomId, std.mem.span(c.colyseus_room_get_id(S.room)));
    try testing.expectEqualStrings("test_room", std.mem.span(c.colyseus_room_get_name(S.room)));

    try leaveAndFree();
}

test "seat reservation: struct form joins the reserved room" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    S.reset();

    const client = try newClient("2567");
    defer freeClient(client);

    const json = try reserveSeat(client);
    defer c.free(json);
    const seat = try parseReservation(json);
    defer seat.deinit();

    // malloc'd, since colyseus_seat_reservation_free() frees them (no strndup on Windows)
    const z = struct {
        fn dup(s: []const u8) [*c]u8 {
            const p: [*c]u8 = @ptrCast(c.malloc(s.len + 1) orelse @panic("OOM"));
            @memcpy(p[0..s.len], s);
            p[s.len] = 0;
            return p;
        }
    };
    var reservation = std.mem.zeroes(c.colyseus_seat_reservation_t);
    reservation.room.name = z.dup(seat.value.name);
    reservation.room.room_id = z.dup(seat.value.roomId);
    reservation.room.process_id = z.dup(seat.value.processId);
    reservation.session_id = z.dup(seat.value.sessionId);

    c.colyseus_client_consume_seat_reservation(client, &reservation, S.onRoom, S.onFail, null);
    // copied: the caller's struct is free to go
    c.colyseus_seat_reservation_free(&reservation);

    try testing.expect(pollUntil(S.joined, 10_000));
    try testing.expectEqualStrings(seat.value.sessionId, std.mem.span(c.colyseus_room_get_session_id(S.room)));

    try leaveAndFree();
}

test "seat reservation: connects to publicAddress instead of the client's endpoint" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    S.reset();

    const fetcher = try newClient("2567");
    defer freeClient(fetcher);
    const json = try reserveSeat(fetcher);
    defer c.free(json);
    const seat = try parseReservation(json);
    defer seat.deinit();

    // nothing listens on the client's own endpoint
    const client = try newClient("1");
    defer freeClient(client);

    const with_address = try std.fmt.allocPrintSentinel(testing.allocator,
        "{{\"name\":\"{s}\",\"roomId\":\"{s}\",\"processId\":\"{s}\",\"sessionId\":\"{s}\",\"publicAddress\":\"localhost:2567\"}}",
        .{ seat.value.name, seat.value.roomId, seat.value.processId, seat.value.sessionId }, 0);
    defer testing.allocator.free(with_address);

    c.colyseus_client_consume_seat_reservation_json(client, with_address.ptr, S.onRoom, S.onFail, null);
    try testing.expect(pollUntil(S.joined, 10_000));
    try testing.expectEqual(@as(u32, 0), S.failed.load(.seq_cst));

    try leaveAndFree();
}

test "seat reservation: an invalid one reports why through on_error, inside colyseus_poll" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);

    const client = try newClient("2567");
    defer freeClient(client);

    const cases = [_]struct { json: [*c]const u8, message: []const u8 }{
        .{ .json = "not json", .message = "Invalid seat reservation: not a JSON object" },
        .{ .json = "[]", .message = "Invalid seat reservation: not a JSON object" },
        .{ .json = "{\"roomId\":\"r\",\"processId\":\"p\",\"sessionId\":\"s\"}", .message = "Invalid seat reservation: missing name" },
        .{ .json = "{\"name\":\"n\",\"processId\":\"p\",\"sessionId\":\"s\"}", .message = "Invalid seat reservation: missing roomId" },
        .{ .json = "{\"name\":\"n\",\"roomId\":\"r\",\"sessionId\":\"s\"}", .message = "Invalid seat reservation: missing processId" },
        .{ .json = "{\"name\":\"n\",\"roomId\":\"r\",\"processId\":\"p\"}", .message = "Invalid seat reservation: missing sessionId" },
    };
    for (cases) |case| {
        S.reset();
        c.colyseus_client_consume_seat_reservation_json(client, case.json, S.onRoom, S.onFail, null);
        try testing.expectEqual(@as(u32, 0), S.failed.load(.seq_cst));
        try testing.expect(pollUntil(S.hasFailed, 1000));
        try testing.expectEqualStrings(case.message, S.failMessage());
        try testing.expectEqual(@as(u32, 0), S.matched.load(.seq_cst));
    }

    // no reservation at all can't be queued — it fails on the spot
    S.reset();
    c.colyseus_client_consume_seat_reservation_json(client, null, S.onRoom, S.onFail, null);
    try testing.expectEqual(@as(u32, 1), S.failed.load(.seq_cst));
    c.colyseus_client_consume_seat_reservation(client, null, S.onRoom, S.onFail, null);
    try testing.expectEqual(@as(u32, 2), S.failed.load(.seq_cst));
}

test "seat reservation: freeing the client drops one not yet delivered" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    S.reset();

    const client = try newClient("2567");
    c.colyseus_client_consume_seat_reservation_json(client, "{}", S.onRoom, S.onFail, null);
    freeClient(client);

    c.colyseus_poll();
    try testing.expectEqual(@as(u32, 0), S.matched.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), S.failed.load(.seq_cst));
}

test "seat reservation: threaded mode answers before the call returns" {
    S.reset();

    const client = try newClient("2567");
    defer freeClient(client);

    const json = try reserveSeat(client);
    defer c.free(json);

    c.colyseus_client_consume_seat_reservation_json(client, json, S.onRoom, S.onFail, null);
    try testing.expectEqual(@as(u32, 1), S.matched.load(.seq_cst));

    var waited: u32 = 0;
    while (!S.joined() and waited < 10_000) : (waited += 10) std.Thread.sleep(10 * ms);
    try testing.expect(S.joined());

    c.colyseus_room_leave(S.room, true);
    waited = 0;
    while (!S.left() and waited < 5000) : (waited += 10) std.Thread.sleep(10 * ms);
    try testing.expect(S.left());
    c.colyseus_room_free(S.room);
}

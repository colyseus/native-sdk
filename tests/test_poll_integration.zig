// The polled runtime against example-server (localhost:2567): with
// colyseus_set_polled(true) and colyseus_poll() as the only driver, every
// callback of a session runs on the polling thread, inside a poll —
// matchmaking, join, state, messages, leave, latency, and both ends of
// auto-reconnection (a successful one, and one that gives up).
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const ms = std.time.ns_per_ms;
const Tid = std.Thread.Id;

// Suites run in parallel against one server: a private room keeps this one's
// callbacks free of other clients (see test_reconnect.zig).
const PRIVATE_ROOM = "{\"private\":true}";

// ─── where callbacks may run ────────────────────────────────────────────────

const Affinity = struct {
    tid: std.atomic.Value(Tid) = .init(0),
    in_poll: std.atomic.Value(bool) = .init(false),
    wrong: std.atomic.Value(u32) = .init(0),

    fn begin(self: *Affinity) void {
        self.tid.store(std.Thread.getCurrentId(), .seq_cst);
        self.wrong.store(0, .seq_cst);
    }

    fn seen(self: *Affinity) void {
        if (std.Thread.getCurrentId() != self.tid.load(.seq_cst) or !self.in_poll.load(.seq_cst)) {
            _ = self.wrong.fetchAdd(1, .seq_cst);
        }
    }
};

var aff: Affinity = .{};

fn pump() void {
    aff.in_poll.store(true, .seq_cst);
    c.colyseus_poll();
    aff.in_poll.store(false, .seq_cst);
}

fn pollUntil(comptime cond: fn () bool, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        pump();
        if (cond()) return true;
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(5 * ms);
    }
}

// ─── session recorder ───────────────────────────────────────────────────────

const S = struct {
    var room: [*c]c.colyseus_room_t = null;
    var matched: std.atomic.Value(u32) = .init(0);
    var match_failed: std.atomic.Value(u32) = .init(0);
    var joins: std.atomic.Value(u32) = .init(0);
    var states: std.atomic.Value(u32) = .init(0);
    var echoes: std.atomic.Value(u32) = .init(0);
    var drops: std.atomic.Value(u32) = .init(0);
    var reconnects: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    var leaves: std.atomic.Value(u32) = .init(0);
    var leave_code: std.atomic.Value(c_int) = .init(0);

    fn reset() void {
        room = null;
        inline for (.{ &matched, &match_failed, &joins, &states, &echoes, &drops, &reconnects, &errors, &leaves }) |v| v.store(0, .seq_cst);
        leave_code.store(0, .seq_cst);
    }

    fn onRoom(r: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        room = r;
        c.colyseus_room_on_join(r, onJoin, null);
        c.colyseus_room_on_state_change(r, onState, null);
        c.colyseus_room_on_message(r, "tagged_echo", onEcho, null);
        c.colyseus_room_on_drop(r, onDrop, null);
        c.colyseus_room_on_reconnect(r, onReconnect, null);
        c.colyseus_room_on_error(r, onError, null);
        c.colyseus_room_on_leave(r, onLeave, null);
        _ = matched.fetchAdd(1, .seq_cst);
    }
    fn onMatchFail(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = match_failed.fetchAdd(1, .seq_cst);
    }
    fn onJoin(_: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = joins.fetchAdd(1, .seq_cst);
    }
    fn onState(_: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = states.fetchAdd(1, .seq_cst);
    }
    fn onEcho(_: ?*c.colyseus_message_reader_t, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = echoes.fetchAdd(1, .seq_cst);
    }
    fn onDrop(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = drops.fetchAdd(1, .seq_cst);
    }
    fn onReconnect(_: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = reconnects.fetchAdd(1, .seq_cst);
    }
    fn onError(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = errors.fetchAdd(1, .seq_cst);
    }
    fn onLeave(code: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        leave_code.store(code, .seq_cst);
        _ = leaves.fetchAdd(1, .seq_cst);
    }

    fn joined() bool {
        return joins.load(.seq_cst) >= 1;
    }
    fn gotState() bool {
        return states.load(.seq_cst) >= 1;
    }
    fn echoed() bool {
        return echoes.load(.seq_cst) >= 1;
    }
    fn dropped() bool {
        return drops.load(.seq_cst) >= 1;
    }
    fn reconnected() bool {
        return reconnects.load(.seq_cst) >= 1;
    }
    fn left() bool {
        return leaves.load(.seq_cst) >= 1;
    }
    fn gaveUp() bool {
        return left() and leave_code.load(.seq_cst) == c.COLYSEUS_CLOSE_FAILED_TO_RECONNECT;
    }
};

const Session = struct {
    settings: [*c]c.colyseus_settings_t,
    client: [*c]c.colyseus_client_t,

    /// A private test_room, joined through matchmaking by polling only.
    fn open() !Session {
        S.reset();
        const settings = c.colyseus_settings_create();
        c.colyseus_settings_set_address(settings, "localhost");
        c.colyseus_settings_set_port(settings, "2567");
        const client = c.colyseus_client_create(settings);
        if (client == null) return error.OutOfMemory;
        c.colyseus_client_create_room(client, "test_room", PRIVATE_ROOM, S.onRoom, S.onMatchFail, null);
        if (!pollUntil(S.joined, 10_000)) return error.NeverJoined;
        return .{ .settings = settings, .client = client };
    }

    fn close(self: Session) void {
        if (S.room != null) c.colyseus_room_free(S.room);
        c.colyseus_client_free(self.client);
        c.colyseus_settings_free(self.settings);
    }
};

fn sendEcho(payload: [*c]const u8) void {
    const msg = c.colyseus_message_map_create();
    defer c.colyseus_message_free(msg);
    c.colyseus_message_map_put_str(msg, "payload", payload);
    c.colyseus_room_send(S.room, "echo", msg);
}

fn forceDrop() void {
    const msg = c.colyseus_message_map_create();
    defer c.colyseus_message_free(msg);
    c.colyseus_room_send(S.room, "force_drop", msg);
}

fn fastReconnect(max_retries: c_int) void {
    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.min_uptime_ms = 0;
    opts.min_delay_ms = 50;
    opts.max_delay_ms = 200;
    opts.delay_ms = 50;
    opts.max_retries = max_retries;
    c.colyseus_room_set_reconnection_options(S.room, &opts);
}

// ─── tests ──────────────────────────────────────────────────────────────────

test "poll: a whole session delivers every callback on the polling thread, inside colyseus_poll" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();

    const session = try Session.open();
    defer session.close();
    try testing.expectEqual(@as(u32, 1), S.matched.load(.seq_cst));

    try testing.expect(pollUntil(S.gotState, 5000));
    // decode only happens inside a poll, so reading state here is race-free
    try testing.expect(c.colyseus_room_get_state(S.room) != null);

    sendEcho("polled");
    try testing.expect(pollUntil(S.echoed, 5000));

    // a quiet stretch with nobody polling: nothing may fire behind our back
    const before = S.states.load(.seq_cst) + S.echoes.load(.seq_cst);
    std.Thread.sleep(300 * ms);
    try testing.expectEqual(before, S.states.load(.seq_cst) + S.echoes.load(.seq_cst));

    c.colyseus_room_leave(S.room, true);
    try testing.expect(pollUntil(S.left, 5000));

    try testing.expectEqual(@as(u32, 0), S.match_failed.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), S.errors.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

test "poll: a dropped connection reconnects from colyseus_poll, on the polling thread" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();

    const session = try Session.open();
    defer session.close();
    fastReconnect(5);

    forceDrop();
    try testing.expect(pollUntil(S.dropped, 5000));
    try testing.expect(c.colyseus_room_is_reconnecting(S.room));

    // queued while down, flushed after the rejoin
    sendEcho("queued-while-down");
    try testing.expect(pollUntil(S.reconnected, 10_000));
    try testing.expect(pollUntil(S.echoed, 5000));
    try testing.expectEqual(@as(u32, 0), S.leaves.load(.seq_cst));

    c.colyseus_room_leave(S.room, true);
    try testing.expect(pollUntil(S.left, 5000));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

// The retry thread gave up by itself: on_leave and the state teardown ran on
// it, while the game loop was reading that state.
test "poll: a reconnect that gives up tears down and reports on the polling thread" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();

    const session = try Session.open();
    defer session.close();
    fastReconnect(2);

    // every retry is refused: a port nothing listens on
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    const port = listener.listen_address.getPort();
    listener.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "ws://127.0.0.1:{d}/test_room?sessionId=x", .{port});
    c.free(S.room.*.endpoint_url);
    S.room.*.endpoint_url = c.strdup(url.ptr);

    forceDrop();
    try testing.expect(pollUntil(S.dropped, 5000));
    try testing.expect(pollUntil(S.gaveUp, 5000));
    try testing.expect(!c.colyseus_room_is_reconnecting(S.room));
    try testing.expectEqual(@as(u32, 0), S.reconnects.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

const Latency = struct {
    var done: std.atomic.Value(u32) = .init(0);
    var ok: std.atomic.Value(bool) = .init(false);

    fn onResult(r: [*c]const c.colyseus_latency_result_t, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        ok.store(r.*.ok, .seq_cst);
        _ = done.fetchAdd(1, .seq_cst);
    }
    fn settled() bool {
        return done.load(.seq_cst) > 0;
    }
};

test "poll: client latency reports on the polling thread" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();
    Latency.done.store(0, .seq_cst);

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");
    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    c.colyseus_client_get_latency(client, null, Latency.onResult, null);
    try testing.expect(pollUntil(Latency.settled, 5000));
    try testing.expect(Latency.ok.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

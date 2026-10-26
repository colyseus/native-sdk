const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("string.h");
});

var message_received: c_int = 0;
var state_changed: c_int = 0;

fn onMessageString(reader: ?*c.colyseus_message_reader_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = reader;
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

// ─── leave() while the connection is down ───────────────────────────────────
//
// A fake transport stands in for the socket: the test decides when each one
// the room opens connects, joins, drops, or ignores a close. Scenarios that
// involve the retry cycle run on both schedulers — the retry thread and the
// polled one.

const CONSENTED: c_int = c.COLYSEUS_CLOSE_CONSENTED;
const FAILED_TO_RECONNECT: c_int = c.COLYSEUS_CLOSE_FAILED_TO_RECONNECT;
const ABNORMAL: c_int = c.COLYSEUS_CLOSE_ABNORMAL_CLOSURE;

const Sock = struct {
    t: c.colyseus_transport_t,
    connecting: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    close_calls: std.atomic.Value(u32) = .init(0),
    leave_sent: std.atomic.Value(u32) = .init(0),
    join_acks: std.atomic.Value(u32) = .init(0),
    data_sent: std.atomic.Value(u32) = .init(0),
    deferred_close: ?c_int = null,
    /// destroy() reports this drop instead of a normal closure
    drop_on_destroy: ?c_int = null,
    /// the next is_open() parks until released, inside whatever lock its caller holds
    hold_is_open: std.atomic.Value(bool) = .init(false),
    in_is_open: std.Thread.ResetEvent = .{},
    release_is_open: std.Thread.ResetEvent = .{},
    /// destroy() parks until released; calls into the socket after it began are counted
    hold_destroy: std.atomic.Value(bool) = .init(false),
    in_destroy: std.Thread.ResetEvent = .{},
    release_destroy: std.Thread.ResetEvent = .{},
    destroyed: std.atomic.Value(bool) = .init(false),
    used_after_destroy: std.atomic.Value(u32) = .init(0),
    /// the socket's own thread, which destroy() joins as the native transport does
    thread: ?std.Thread = null,

    fn touch(s: *Sock) void {
        if (s.destroyed.load(.seq_cst)) _ = s.used_after_destroy.fetchAdd(1, .seq_cst);
    }
};

/// The socket whose callback this thread is inside: its close() reports after
/// the callback returns, as the native transport does from its own tick.
threadlocal var dispatching: ?*Sock = null;

const Fake = struct {
    var socks: [16]*Sock = undefined;
    var count: std.atomic.Value(u32) = .init(0);
    /// close() can't abort a socket while it connects, like a transport that
    /// has no way to cancel a connecting socket
    var sticky: bool = false;
    /// leave() lands while connect() runs, and connect() then fails before a socket exists
    var leave_then_fail: bool = false;
    /// the next connect() parks until released, as a DNS lookup holds the retry thread
    var hold_connect: std.atomic.Value(bool) = .init(false);
    var in_connect: std.Thread.ResetEvent = .{};
    var release_connect: std.Thread.ResetEvent = .{};

    fn sock(i: u32) *Sock {
        return socks[i];
    }

    fn reset() void {
        for (socks[0..count.load(.seq_cst)]) |s| std.heap.c_allocator.destroy(s);
        count.store(0, .seq_cst);
        sticky = false;
        leave_then_fail = false;
        hold_connect.store(false, .seq_cst);
        in_connect = .{};
        release_connect = .{};
    }

    fn factory(events: [*c]const c.colyseus_transport_events_t) callconv(.c) [*c]c.colyseus_transport_t {
        const s = std.heap.c_allocator.create(Sock) catch return null;
        s.* = .{ .t = std.mem.zeroInit(c.colyseus_transport_t, .{}) };
        s.t.connect = connect;
        s.t.send = send;
        s.t.close = close;
        s.t.is_open = isOpen;
        s.t.destroy = destroy;
        s.t.events = events.*;
        s.t.impl_data = s;
        socks[count.load(.seq_cst)] = s;
        _ = count.fetchAdd(1, .seq_cst);
        return &s.t;
    }

    fn of(t: [*c]const c.colyseus_transport_t) *Sock {
        return @ptrCast(@alignCast(t.*.impl_data));
    }

    fn connect(t: [*c]c.colyseus_transport_t, _: [*c]const u8) callconv(.c) void {
        const s = of(t);
        if (leave_then_fail) {
            c.colyseus_room_leave(Ev.room.?, true);
            s.t.events.on_error.?("Failed to initialize connection", s.t.events.userdata);
            return;
        }
        s.connecting.store(true, .seq_cst);
        if (hold_connect.swap(false, .seq_cst)) {
            in_connect.set();
            release_connect.wait();
        }
    }

    fn send(t: [*c]c.colyseus_transport_t, data: [*c]const u8, len: usize) callconv(.c) void {
        of(t).touch();
        if (len == 1 and data[0] == c.COLYSEUS_PROTOCOL_LEAVE_ROOM) _ = of(t).leave_sent.fetchAdd(1, .seq_cst);
        if (len == 1 and data[0] == c.COLYSEUS_PROTOCOL_JOIN_ROOM) _ = of(t).join_acks.fetchAdd(1, .seq_cst);
        if (len > 0 and data[0] == c.COLYSEUS_PROTOCOL_ROOM_DATA_BYTES) _ = of(t).data_sent.fetchAdd(1, .seq_cst);
    }

    fn close(t: [*c]c.colyseus_transport_t, code: c_int, reason: [*c]const u8) callconv(.c) void {
        const s = of(t);
        s.touch();
        _ = s.close_calls.fetchAdd(1, .seq_cst);
        if (sticky and !s.open.load(.seq_cst)) return;
        // aborting a connect reports on_error first, as real transports do
        if (s.connecting.load(.seq_cst) and !s.open.load(.seq_cst) and !s.closed.load(.seq_cst)) {
            s.t.events.on_error.?("WebSocket error", s.t.events.userdata);
        }
        finishClose(s, code, reason);
    }

    fn finishClose(s: *Sock, code: c_int, reason: [*c]const u8) void {
        if (dispatching == s) {
            if (s.deferred_close == null) s.deferred_close = code;
            return;
        }
        if (s.closed.swap(true, .seq_cst)) return;
        s.open.store(false, .seq_cst);
        s.t.events.on_close.?(code, reason, s.t.events.userdata);
    }

    fn isOpen(t: [*c]const c.colyseus_transport_t) callconv(.c) bool {
        const s = of(t);
        s.touch();
        if (s.hold_is_open.swap(false, .seq_cst)) {
            s.in_is_open.set();
            s.release_is_open.wait();
        }
        return s.open.load(.seq_cst);
    }

    /// Freed by reset(), so a test can still look at it after the room let go.
    fn destroy(t: [*c]c.colyseus_transport_t) callconv(.c) void {
        const s = of(t);
        if (s.thread) |thread| thread.join();
        s.destroyed.store(true, .seq_cst);
        if (s.hold_destroy.swap(false, .seq_cst)) {
            s.in_destroy.set();
            s.release_destroy.wait();
        }
        if (s.drop_on_destroy) |code| return finishClose(s, code, "drop");
        finishClose(s, 1000, "Normal closure");
    }
};

/// Runs one of `s`'s callbacks the way its driving thread would.
fn deliver(s: *Sock, frame: []const u8) void {
    dispatching = s;
    s.t.events.on_message.?(frame.ptr, frame.len, s.t.events.userdata);
    dispatching = null;
    if (s.deferred_close) |code| {
        s.deferred_close = null;
        Fake.finishClose(s, code, "Leave");
    }
}

// JOIN_ROOM: reconnection token "tok", serializer "none", no state
const join_room = [_]u8{ c.COLYSEUS_PROTOCOL_JOIN_ROOM, 3, 't', 'o', 'k', 4, 'n', 'o', 'n', 'e' };

fn sockOpen(s: *Sock) void {
    s.open.store(true, .seq_cst);
    s.t.events.on_open.?(s.t.events.userdata);
}

fn sockJoin(s: *Sock) void {
    sockOpen(s);
    deliver(s, &join_room);
}

/// The server closed the socket, or the network dropped it.
fn sockDrop(s: *Sock, code: c_int) void {
    Fake.finishClose(s, code, "drop");
}

const Ev = struct {
    var room: ?*c.colyseus_room_t = null;
    var leaves: std.atomic.Value(u32) = .init(0);
    var leave_code: std.atomic.Value(c_int) = .init(0);
    var drops: std.atomic.Value(u32) = .init(0);
    var reconnects: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    /// on_drop calls leave() with this consent
    var leave_on_drop: ?bool = null;
    var leave_on_leave: bool = false;
    var send_on_drop: bool = false;

    fn reset() void {
        room = null;
        leaves.store(0, .seq_cst);
        leave_code.store(0, .seq_cst);
        drops.store(0, .seq_cst);
        reconnects.store(0, .seq_cst);
        errors.store(0, .seq_cst);
        leave_on_drop = null;
        leave_on_leave = false;
        send_on_drop = false;
    }

    fn onLeave(code: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        leave_code.store(code, .seq_cst);
        // capped: re-entry has to fail the test, not overflow the stack
        if (leaves.fetchAdd(1, .seq_cst) < 3 and leave_on_leave) c.colyseus_room_leave(room.?, true);
    }

    fn onDrop(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        _ = drops.fetchAdd(1, .seq_cst);
        if (send_on_drop) c.colyseus_room_send_bytes(room.?, "x", "y", 1);
        if (leave_on_drop) |consented| c.colyseus_room_leave(room.?, consented);
    }

    fn onReconnect(_: ?*anyopaque) callconv(.c) void {
        _ = reconnects.fetchAdd(1, .seq_cst);
    }

    fn onError(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        _ = errors.fetchAdd(1, .seq_cst);
    }
};

const Scheduler = enum { threaded, polled };

/// Reconnection options; the room reads them when its socket drops.
const Opts = struct {
    retry_ms: c_int = 10,
    min_uptime_ms: c_int = 0,
    max_retries: ?c_int = null,
    /// pass Connect's callbacks to colyseus_room_connect
    connect_callbacks: bool = false,
};

/// colyseus_room_connect's own callbacks.
const Connect = struct {
    var successes: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    var error_code: std.atomic.Value(c_int) = .init(0);

    fn reset() void {
        successes.store(0, .seq_cst);
        errors.store(0, .seq_cst);
        error_code.store(0, .seq_cst);
    }

    fn onSuccess(_: ?*anyopaque) callconv(.c) void {
        _ = successes.fetchAdd(1, .seq_cst);
    }

    fn onError(code: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        error_code.store(code, .seq_cst);
        _ = errors.fetchAdd(1, .seq_cst);
    }
};

/// A room on `scheduler` whose first socket is connecting.
fn connectRoom(scheduler: Scheduler, o: Opts) *c.colyseus_room_t {
    Fake.reset();
    Ev.reset();
    Connect.reset();

    // the room picks its scheduler when it connects
    c.colyseus_set_polled(scheduler == .polled);
    defer c.colyseus_set_polled(false);

    const room = c.colyseus_room_create("leave_test", Fake.factory).?;
    Ev.room = room;
    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.min_uptime_ms = o.min_uptime_ms;
    opts.min_delay_ms = o.retry_ms;
    opts.max_delay_ms = o.retry_ms;
    opts.delay_ms = o.retry_ms;
    if (o.max_retries) |n| opts.max_retries = n;
    c.colyseus_room_set_reconnection_options(room, &opts);
    c.colyseus_room_on_leave(room, Ev.onLeave, null);
    c.colyseus_room_on_drop(room, Ev.onDrop, null);
    c.colyseus_room_on_reconnect(room, Ev.onReconnect, null);
    c.colyseus_room_on_error(room, Ev.onError, null);
    if (o.connect_callbacks) {
        c.colyseus_room_connect(room, "ws://fake/leave_test?sessionId=s", null, Connect.onSuccess, Connect.onError, null);
    } else {
        c.colyseus_room_connect(room, "ws://fake/leave_test?sessionId=s", null, null, null, null);
    }
    return room;
}

fn joinRoom(scheduler: Scheduler, o: Opts) !*c.colyseus_room_t {
    const room = connectRoom(scheduler, o);
    sockJoin(Fake.sock(0));
    try testing.expect(room.*.has_joined);
    return room;
}

fn freeRoom(room: *c.colyseus_room_t) void {
    c.colyseus_room_free(room);
    Fake.reset();
}

/// Waits for `cond`, driving the polled scheduler meanwhile.
fn waitFor(comptime cond: fn () bool, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        c.colyseus_reconnect_poll();
        if (cond()) return true;
        if (timer.read() >= timeout_ms * std.time.ns_per_ms) return false;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn never() bool {
    return false;
}

/// Lets `ms` pass with the polled scheduler driven, so a retry would fire.
fn settle(ms: u64) void {
    _ = waitFor(never, ms);
}

/// Whether reconnect attempt `n` (the room's socket `n`) is connecting.
fn attemptConnectingN(comptime n: u32) fn () bool {
    return struct {
        fn f() bool {
            return Fake.count.load(.seq_cst) > n and Fake.sock(n).connecting.load(.seq_cst);
        }
    }.f;
}

fn attemptCloseCalled() bool {
    return Fake.sock(1).close_calls.load(.seq_cst) >= 1;
}

fn attemptClosed() bool {
    return Fake.sock(1).closed.load(.seq_cst);
}

fn left() bool {
    return Ev.leaves.load(.seq_cst) >= 1;
}

fn expectLeftOnce(code: c_int) !void {
    try testing.expectEqual(@as(u32, 1), Ev.leaves.load(.seq_cst));
    try testing.expectEqual(code, Ev.leave_code.load(.seq_cst));
}

fn leaveBetweenRetries(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{ .retry_ms = 100 });
    defer freeRoom(room);

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(c.colyseus_room_is_reconnecting(room));

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(CONSENTED);
    try testing.expect(!c.colyseus_room_is_reconnecting(room));

    settle(150); // past the retry delay
    try testing.expectEqual(@as(u32, 1), Fake.count.load(.seq_cst));
    try expectLeftOnce(CONSENTED);
}

test "leave: between retries, cancels the pending retry (threaded)" {
    try leaveBetweenRetries(.threaded);
}

test "leave: between retries, cancels the pending retry (polled)" {
    try leaveBetweenRetries(.polled);
}

fn leaveWhileAttemptConnecting(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(CONSENTED);

    // the retry thread closes its own attempt, a moment later
    try testing.expect(waitFor(attemptClosed, 2000));
    settle(50);
    try testing.expectEqual(@as(u32, 2), Fake.count.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), Ev.drops.load(.seq_cst));
    // a room that has left ignores the aborted socket's error
    try testing.expectEqual(@as(u32, 0), Ev.errors.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));
    try expectLeftOnce(CONSENTED);
}

test "leave: aborts a reconnect attempt that is still connecting (threaded)" {
    try leaveWhileAttemptConnecting(.threaded);
}

test "leave: aborts a reconnect attempt that is still connecting (polled)" {
    try leaveWhileAttemptConnecting(.polled);
}

fn attemptLandsAfterLeave(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);
    Fake.sticky = true; // only the reconnect attempt ignores close()

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(CONSENTED);
    try testing.expect(waitFor(attemptCloseCalled, 2000));

    // the attempt connects anyway, and the server lets it back in
    sockJoin(Fake.sock(1));
    try testing.expectEqual(@as(u32, 0), Ev.reconnects.load(.seq_cst));
    // unacked, the server doesn't hold a seat for the closed socket
    try testing.expectEqual(@as(u32, 0), Fake.sock(1).join_acks.load(.seq_cst));
    try testing.expect(Fake.sock(1).closed.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));
    try expectLeftOnce(CONSENTED);
}

test "leave: a reconnect that lands afterwards does not revive the room (threaded)" {
    try attemptLandsAfterLeave(.threaded);
}

test "leave: a reconnect that lands afterwards does not revive the room (polled)" {
    try attemptLandsAfterLeave(.polled);
}

fn leaveFromOnDrop(scheduler: Scheduler, min_uptime_ms: c_int, consented: bool) !void {
    const room = try joinRoom(scheduler, .{ .min_uptime_ms = min_uptime_ms });
    defer freeRoom(room);
    Ev.leave_on_drop = consented;

    sockDrop(Fake.sock(0), ABNORMAL);
    try expectLeftOnce(CONSENTED);
    try testing.expectEqual(@as(u32, 1), Fake.count.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));
}

test "leave: from an on_drop listener, does not reconnect (threaded)" {
    try leaveFromOnDrop(.threaded, 0, true);
}

test "leave: from an on_drop listener, does not reconnect (polled)" {
    try leaveFromOnDrop(.polled, 0, true);
}

test "leave: leave(false) from an on_drop listener does not reconnect (threaded)" {
    try leaveFromOnDrop(.threaded, 0, false);
}

test "leave: leave(false) from an on_drop listener does not reconnect (polled)" {
    try leaveFromOnDrop(.polled, 0, false);
}

test "leave: from the first on_drop, before min uptime, is still consented (threaded)" {
    try leaveFromOnDrop(.threaded, 60_000, true);
}

test "leave: from the first on_drop, before min uptime, is still consented (polled)" {
    try leaveFromOnDrop(.polled, 60_000, true);
}

/// A consented leave() of a joined room, then the socket's close: leave()
/// sends LEAVE_ROOM on an open socket, nothing on one already closed.
fn leaveThenClose(scheduler: Scheduler, socket_open: bool, code: c_int, want: c_int) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);

    // the server closed the socket; the room hears of it on the socket's next tick
    if (!socket_open) Fake.sock(0).open.store(false, .seq_cst);
    c.colyseus_room_leave(room, true);
    try testing.expectEqual(@as(u32, @intFromBool(socket_open)), Fake.sock(0).leave_sent.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Ev.leaves.load(.seq_cst)); // waits for the close

    sockDrop(Fake.sock(0), code);
    try expectLeftOnce(want);
    try testing.expectEqual(@as(u32, 0), Ev.drops.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), Fake.count.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));
}

test "leave: on an open connection, waits for the server's close" {
    try leaveThenClose(.threaded, true, CONSENTED, CONSENTED);
}

test "leave: a drop after LEAVE_ROOM was sent is a consented leave (threaded)" {
    try leaveThenClose(.threaded, true, ABNORMAL, CONSENTED);
}

test "leave: a drop after LEAVE_ROOM was sent is a consented leave (polled)" {
    try leaveThenClose(.polled, true, ABNORMAL, CONSENTED);
}

test "leave: with the server's close in flight, keeps the server's code (threaded)" {
    try leaveThenClose(.threaded, false, 4321, 4321);
}

test "leave: with the server's close in flight, keeps the server's code (polled)" {
    try leaveThenClose(.polled, false, 4321, 4321);
}

test "leave: with a drop in flight, ends as a consented leave (threaded)" {
    try leaveThenClose(.threaded, false, ABNORMAL, CONSENTED);
}

test "leave: with a drop in flight, ends as a consented leave (polled)" {
    try leaveThenClose(.polled, false, ABNORMAL, CONSENTED);
}

test "leave: on a room that already left, on_leave does not fire again" {
    const room = try joinRoom(.threaded, .{});
    defer freeRoom(room);
    Ev.leave_on_leave = true;

    // kicked with an app-defined code; on_leave calls leave() again
    sockDrop(Fake.sock(0), 4321);
    try expectLeftOnce(4321);

    c.colyseus_room_leave(room, true);
    c.colyseus_room_leave(room, false);
    try expectLeftOnce(4321);
}

fn retriesRunOut(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{ .max_retries = 2 });
    defer freeRoom(room);

    sockDrop(Fake.sock(0), ABNORMAL);
    inline for (.{ 1, 2 }) |n| {
        try testing.expect(waitFor(attemptConnectingN(n), 2000));
        sockDrop(Fake.sock(n), ABNORMAL);
    }

    try testing.expect(waitFor(left, 2000));
    settle(50);
    try expectLeftOnce(FAILED_TO_RECONNECT);
    try testing.expectEqual(@as(u32, 3), Fake.count.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(FAILED_TO_RECONNECT);
}

test "leave: retries running out fire on_leave(FAILED_TO_RECONNECT) once (threaded)" {
    try retriesRunOut(.threaded);
}

test "leave: retries running out fire on_leave(FAILED_TO_RECONNECT) once (polled)" {
    try retriesRunOut(.polled);
}

test "leave: while the first connect is in progress, aborts it" {
    const room = connectRoom(.threaded, .{});
    defer freeRoom(room);

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(CONSENTED);
    try testing.expect(Fake.sock(0).closed.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Ev.errors.load(.seq_cst));
}

test "leave: non-consented closes with 1000 and does not reconnect" {
    const room = try joinRoom(.threaded, .{});
    defer freeRoom(room);

    c.colyseus_room_leave(room, false);
    try testing.expectEqual(@as(u32, 0), Fake.sock(0).leave_sent.load(.seq_cst));
    try expectLeftOnce(1000);
    try testing.expectEqual(@as(u32, 0), Ev.drops.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), Fake.count.load(.seq_cst));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));
}

fn leaveConsented(room: *c.colyseus_room_t) void {
    c.colyseus_room_leave(room, true);
}

fn serverCloses(s: *Sock) void {
    sockDrop(s, CONSENTED);
}

test "leave: the server's close does not wait on the retry lock" {
    // colyseus_room_free destroys that lock before it joins the socket's
    // thread, so a close landing meanwhile must not reach for it
    const room = try joinRoom(.threaded, .{});
    defer freeRoom(room);
    const s = Fake.sock(0);

    // leave() asks is_open() under the retry lock: hold it there
    s.hold_is_open.store(true, .seq_cst);
    const leaver = try std.Thread.spawn(.{}, leaveConsented, .{room});
    s.in_is_open.wait();

    const closer = try std.Thread.spawn(.{}, serverCloses, .{s});
    const landed = waitFor(left, 500);
    s.release_is_open.set();
    leaver.join();
    closer.join();

    try testing.expect(landed);
    try expectLeftOnce(CONSENTED);
}

fn leaveWhileAttemptOpenNotJoined(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));

    // the attempt's socket opened; JOIN_ROOM hasn't arrived
    const s = Fake.sock(1);
    sockOpen(s);

    c.colyseus_room_leave(room, true);
    try expectLeftOnce(CONSENTED);
    try testing.expectEqual(@as(u32, 0), s.leave_sent.load(.seq_cst));
    try testing.expect(waitFor(attemptClosed, 2000));

    settle(50);
    try testing.expectEqual(@as(u32, 2), Fake.count.load(.seq_cst));
    try expectLeftOnce(CONSENTED);
}

test "leave: an attempt open but not yet joined is finished locally and closed (threaded)" {
    try leaveWhileAttemptOpenNotJoined(.threaded);
}

test "leave: an attempt open but not yet joined is finished locally and closed (polled)" {
    try leaveWhileAttemptOpenNotJoined(.polled);
}

fn attemptFailsAfterLeave(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);
    Fake.leave_then_fail = true;

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(left, 2000));
    settle(50);
    try testing.expectEqual(@as(u32, 0), Ev.errors.load(.seq_cst));
    try testing.expectEqual(@as(u32, 2), Fake.count.load(.seq_cst));
    try expectLeftOnce(CONSENTED);
}

test "leave: a connect() failing after leave() does not reach on_error (threaded)" {
    try attemptFailsAfterLeave(.threaded);
}

test "leave: a connect() failing after leave() does not reach on_error (polled)" {
    try attemptFailsAfterLeave(.polled);
}

// ─── colyseus_room_connect's callbacks ──────────────────────────────────────

test "connect: on_error fires once when the socket closes before JOIN_ROOM" {
    const room = connectRoom(.threaded, .{ .connect_callbacks = true });
    defer freeRoom(room);
    const s = Fake.sock(0);

    sockDrop(s, 4002);
    s.t.events.on_error.?("WebSocket error", s.t.events.userdata);
    try testing.expectEqual(@as(u32, 1), Connect.errors.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 4002), Connect.error_code.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Connect.successes.load(.seq_cst));
}

test "connect: on_error fires once, with the server's code, when it refuses the join" {
    const room = connectRoom(.threaded, .{ .connect_callbacks = true });
    defer freeRoom(room);
    const s = Fake.sock(0);

    // ERROR (code 42, "refused"), and the server closes right behind it
    sockOpen(s);
    deliver(s, &[_]u8{ c.COLYSEUS_PROTOCOL_ERROR, 42, 0xa7, 'r', 'e', 'f', 'u', 's', 'e', 'd' });
    sockDrop(s, 4002);
    try testing.expectEqual(@as(u32, 1), Connect.errors.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 42), Connect.error_code.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Connect.successes.load(.seq_cst));
}

test "connect: on_error reports a connect() that fails before a socket exists" {
    const room = connectRoom(.threaded, .{ .connect_callbacks = true });
    defer freeRoom(room);
    const s = Fake.sock(0);

    s.t.events.on_error.?("Failed to initialize connection", s.t.events.userdata);
    try testing.expectEqual(@as(u32, 1), Connect.errors.load(.seq_cst));
    try testing.expectEqual(@as(c_int, -1), Connect.error_code.load(.seq_cst));
}

test "connect: on_success fires once, on the first JOIN_ROOM" {
    const room = try joinRoom(.threaded, .{ .connect_callbacks = true });
    defer freeRoom(room);
    try testing.expectEqual(@as(u32, 1), Connect.successes.load(.seq_cst));

    // a drop and a reconnect are the room's business, not the connect's
    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));
    sockJoin(Fake.sock(1));
    try testing.expectEqual(@as(u32, 1), Ev.reconnects.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), Connect.successes.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Connect.errors.load(.seq_cst));
}

// ─── the retry thread swapping the socket under other callers ──────────────

fn sendOne(room: *c.colyseus_room_t) void {
    c.colyseus_room_send_bytes(room, "x", "y", 1);
}

fn onPing(_: c_int, _: ?*anyopaque) callconv(.c) void {}

test "reconnect: calls while the retry thread destroys the dropped socket don't reach it" {
    const room = try joinRoom(.threaded, .{});
    defer freeRoom(room);
    const s = Fake.sock(0);
    s.hold_destroy.store(true, .seq_cst);

    sockDrop(s, ABNORMAL);
    s.in_destroy.wait(); // the retry thread is tearing the dropped socket down

    sendOne(room);
    try testing.expect(!c.colyseus_room_is_connected(room));
    c.colyseus_room_ping(room, onPing, null);
    s.release_destroy.set();

    try testing.expect(waitFor(attemptConnectingN(1), 2000));
    try testing.expectEqual(@as(u32, 0), s.used_after_destroy.load(.seq_cst));
}

test "reconnect: the retry thread waits for a send in progress before destroying the socket" {
    const room = try joinRoom(.threaded, .{ .retry_ms = 20 });
    defer freeRoom(room);
    const s = Fake.sock(0);

    // a send is inside the socket's is_open() when the socket drops
    s.hold_is_open.store(true, .seq_cst);
    const sender = try std.Thread.spawn(.{}, sendOne, .{room});
    s.in_is_open.wait();
    sockDrop(s, ABNORMAL);

    settle(100); // past the retry delay
    const destroyed_in_use = s.destroyed.load(.seq_cst);
    s.release_is_open.set();
    sender.join();
    try testing.expect(!destroyed_in_use);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));
}

fn sendFromOnDrop(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    defer freeRoom(room);
    Ev.send_on_drop = true;

    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));
    sockJoin(Fake.sock(1));
    try testing.expectEqual(@as(u32, 1), Ev.reconnects.load(.seq_cst));
    // what on_drop sent was queued, and goes out on the reconnected socket
    try testing.expectEqual(@as(u32, 1), Fake.sock(1).data_sent.load(.seq_cst));
}

test "reconnect: a send from on_drop is queued for the reconnection (threaded)" {
    try sendFromOnDrop(.threaded);
}

test "reconnect: a send from on_drop is queued for the reconnection (polled)" {
    try sendFromOnDrop(.polled);
}

// ─── colyseus_room_free while a socket's thread still reports ───────────────

fn freeThenSignal(room: *c.colyseus_room_t, freed: *std.Thread.ResetEvent) void {
    c.colyseus_room_free(room);
    freed.set();
}

fn retriesCancelled() bool {
    return @atomicLoad(bool, &Ev.room.?.*.reconnection.cancelled, .seq_cst);
}

test "free: an attempt failing while the room is freed does not start another cycle" {
    const room = try joinRoom(.threaded, .{});
    Fake.hold_connect.store(true, .seq_cst);

    sockDrop(Fake.sock(0), ABNORMAL);
    Fake.in_connect.wait(); // the retry thread is inside the attempt's connect()

    var freed: std.Thread.ResetEvent = .{};
    const freer = try std.Thread.spawn(.{}, freeThenSignal, .{ room, &freed });
    // free cancelled the cycle and now joins the retry thread
    try testing.expect(waitFor(retriesCancelled, 2000));

    // the attempt fails on its socket's thread meanwhile
    sockDrop(Fake.sock(1), ABNORMAL);
    Fake.release_connect.set();

    // a new cycle would keep the retry thread waiting on that attempt, and free with it
    freed.timedWait(2 * std.time.ns_per_s) catch return error.FreeHung;
    freer.join();
    Fake.reset();
    try expectLeftOnce(ABNORMAL);
}

fn dropWhileFreed(scheduler: Scheduler) !void {
    const room = try joinRoom(scheduler, .{});
    sockDrop(Fake.sock(0), ABNORMAL);
    try testing.expect(waitFor(attemptConnectingN(1), 2000));

    // the attempt drops as free tears its socket down: no cycle is left to retry it
    Fake.sock(1).drop_on_destroy = ABNORMAL;
    c.colyseus_room_free(room);
    Fake.reset();
    try expectLeftOnce(ABNORMAL);
}

test "free: a drop landing while the room is freed ends it with the drop's code (threaded)" {
    try dropWhileFreed(.threaded);
}

test "free: a drop landing while the room is freed ends it with the drop's code (polled)" {
    try dropWhileFreed(.polled);
}

/// ROOM_DATA "m", no payload
const room_data_m = [_]u8{ c.COLYSEUS_PROTOCOL_ROOM_DATA, 0xa1, 'm' };

/// An on_message handler that holds its socket's thread until free begins.
const SlowHandler = struct {
    var inside: std.Thread.ResetEvent = .{};

    fn onMessage(_: ?*c.colyseus_message_reader_t, _: ?*anyopaque) callconv(.c) void {
        inside.set();
        while (!retriesCancelled()) std.Thread.sleep(std.time.ns_per_ms);
    }
};

test "free: a callback running on the socket's thread is not a free from inside a callback" {
    const room = try joinRoom(.threaded, .{});
    c.colyseus_room_on_message(room, "m", SlowHandler.onMessage, null);
    SlowHandler.inside = .{};

    const s = Fake.sock(0);
    s.thread = try std.Thread.spawn(.{}, deliver, .{ s, @as([]const u8, &room_data_m) });
    SlowHandler.inside.wait();

    // the app frees the room meanwhile; destroying its socket joins that thread
    freeRoom(room);
    try expectLeftOnce(1000);
}

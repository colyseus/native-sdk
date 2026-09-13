// Offline regressions for the native WebSocket transport. Each test brings its
// own loopback peer — a minimal RFC 6455 upgrade responder — so none needs a
// server:
//   - `localhost` served on one address family only (Vite binds ::1) opens
//   - nothing listening: on_close(1006, "Connection refused") fires promptly
//   - a write to a peer that reset the connection errors instead of raising
//     SIGPIPE (exit 141)
//   - polled mode starts no tick thread, and every callback runs inside
//     colyseus_ws_poll(), on its caller
//
// POSIX only (build.zig skips it on Windows): the peer is BSD sockets, and
// Windows has no SIGPIPE.
const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const c = @cImport({
    @cInclude("colyseus.h");
    // tick_thread / polled: whether connect started a thread
    @cInclude("network/websocket_transport_internal.h");
});

const ms = std.time.ns_per_ms;
const Tid = std.Thread.Id;
const Transport = [*c]c.colyseus_transport_t;

// ─── callback recorder ──────────────────────────────────────────────────────

const Rec = struct {
    opened: std.atomic.Value(u32) = .init(0),
    messages: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(u32) = .init(0),
    errored: std.atomic.Value(u32) = .init(0),
    close_code: std.atomic.Value(c_int) = .init(0),
    reason_buf: [64]u8 = undefined,
    reason_len: std.atomic.Value(usize) = .init(0),
    /// Nonzero: every callback must run on this thread.
    want_tid: std.atomic.Value(Tid) = .init(0),
    /// Nonzero: no callback may run on this thread.
    forbid_tid: std.atomic.Value(Tid) = .init(0),
    wrong_thread: std.atomic.Value(u32) = .init(0),

    fn events(self: *Rec) c.colyseus_transport_events_t {
        return .{
            .on_open = onOpen,
            .on_message = onMessage,
            .on_close = onClose,
            .on_error = onError,
            .userdata = self,
        };
    }

    fn seen(self: *Rec) void {
        const tid = std.Thread.getCurrentId();
        const want = self.want_tid.load(.seq_cst);
        const forbid = self.forbid_tid.load(.seq_cst);
        if ((want != 0 and tid != want) or (forbid != 0 and tid == forbid)) {
            _ = self.wrong_thread.fetchAdd(1, .seq_cst);
        }
    }

    fn total(self: *Rec) u32 {
        return self.opened.load(.seq_cst) + self.messages.load(.seq_cst) +
            self.closed.load(.seq_cst) + self.errored.load(.seq_cst);
    }

    fn reason(self: *Rec) []const u8 {
        return self.reason_buf[0..self.reason_len.load(.seq_cst)];
    }
};

fn recOf(ud: ?*anyopaque) *Rec {
    return @ptrCast(@alignCast(ud.?));
}

fn onOpen(ud: ?*anyopaque) callconv(.c) void {
    const r = recOf(ud);
    r.seen();
    _ = r.opened.fetchAdd(1, .seq_cst);
}
fn onMessage(_: [*c]const u8, _: usize, ud: ?*anyopaque) callconv(.c) void {
    const r = recOf(ud);
    r.seen();
    _ = r.messages.fetchAdd(1, .seq_cst);
}
fn onClose(code: c_int, reason: [*c]const u8, ud: ?*anyopaque) callconv(.c) void {
    const r = recOf(ud);
    r.seen();
    r.close_code.store(code, .seq_cst);
    if (reason != null) {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(reason)));
        const n = @min(s.len, r.reason_buf.len);
        @memcpy(r.reason_buf[0..n], s[0..n]);
        r.reason_len.store(n, .seq_cst);
    }
    _ = r.closed.fetchAdd(1, .seq_cst);
}
fn onError(_: [*c]const u8, ud: ?*anyopaque) callconv(.c) void {
    const r = recOf(ud);
    r.seen();
    _ = r.errored.fetchAdd(1, .seq_cst);
}

fn isOpen(r: *Rec) bool {
    return r.opened.load(.seq_cst) > 0;
}
fn hasMessage(r: *Rec) bool {
    return r.messages.load(.seq_cst) > 0;
}
fn isClosed(r: *Rec) bool {
    return r.closed.load(.seq_cst) > 0;
}

/// Waits up to `timeout_ms` for `cond`, ticking polled sockets on this thread
/// when `pump` is set.
fn waitUntil(r: *Rec, comptime cond: fn (*Rec) bool, pump: bool, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        if (pump) c.colyseus_ws_poll();
        if (cond(r)) return true;
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(2 * ms);
    }
}

// ─── transport helpers ──────────────────────────────────────────────────────

const Mode = enum { threaded, polled };

fn connect(r: *Rec, host: []const u8, port: u16) !Transport {
    var ev = r.events();
    const t = c.colyseus_websocket_transport_create(&ev);
    if (t == null) return error.OutOfMemory;
    var buf: [96]u8 = undefined;
    c.colyseus_transport_connect(t, (try std.fmt.bufPrintZ(&buf, "ws://{s}:{d}", .{ host, port })).ptr);
    return t;
}

fn impl(t: Transport) *c.colyseus_ws_transport_data_t {
    return @ptrCast(@alignCast(t.*.impl_data));
}

// ─── loopback peer ──────────────────────────────────────────────────────────

const ws_peer = @import("ws_peer.zig");
const Family = ws_peer.Family;
const Peer = ws_peer.Peer;
const skip = ws_peer.skip;
const freePort = ws_peer.freePort;

// ─── address resolution ─────────────────────────────────────────────────────

/// Skips unless `localhost` resolves to `family` here, with a second address
/// to fall through to.
fn requireLocalhostOn(family: Family) !void {
    const list = try std.net.getAddressList(testing.allocator, "localhost", 80);
    defer list.deinit();
    const want: u32 = if (family == .ip6) posix.AF.INET6 else posix.AF.INET;
    for (list.addrs) |a| if (a.any.family == want) return;
    return skip("localhost does not resolve to that family on this host");
}

fn expectLocalhostOpens(family: Family) !void {
    try requireLocalhostOn(family);
    var peer: Peer = undefined;
    try peer.start(family);
    defer peer.stop();

    var rec: Rec = .{};
    const t = try connect(&rec, "localhost", peer.listener.port);
    defer c.colyseus_transport_destroy(t);
    try testing.expect(waitUntil(&rec, isOpen, false, 3000));
    try testing.expectEqual(@as(u32, 0), rec.closed.load(.seq_cst));
}

// Vite binds `localhost` on ::1 only; a client that tried one IPv4 address
// never opened and never said why.
test "transport: ws://localhost opens against a listener on ::1 only" {
    try expectLocalhostOpens(.ip6);
}

// The mirror image: whichever family the resolver lists first, the other one
// is reached by falling through a refused address.
test "transport: ws://localhost opens against a listener on 127.0.0.1 only" {
    try expectLocalhostOpens(.ip4);
}

// ─── refused connection ─────────────────────────────────────────────────────

fn expectRefused(mode: Mode) !void {
    c.colyseus_ws_set_polled(mode == .polled);
    defer c.colyseus_ws_set_polled(false);

    const me = std.Thread.getCurrentId();
    var rec: Rec = .{};
    switch (mode) {
        .polled => rec.want_tid.store(me, .seq_cst),
        .threaded => rec.forbid_tid.store(me, .seq_cst),
    }

    // localhost: every resolved address must be tried and refused
    const t = try connect(&rec, "localhost", try freePort());
    defer c.colyseus_transport_destroy(t);
    if (mode == .polled) try testing.expectEqual(@as(u32, 0), rec.total());

    try testing.expect(waitUntil(&rec, isClosed, mode == .polled, 2000));
    try testing.expectEqual(@as(c_int, 1006), rec.close_code.load(.seq_cst));
    try testing.expectEqualStrings("Connection refused", rec.reason());
    try testing.expectEqual(@as(u32, 1), rec.closed.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), rec.opened.load(.seq_cst) + rec.errored.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), rec.wrong_thread.load(.seq_cst));
}

test "transport: nothing listening closes promptly with \"Connection refused\" (threaded)" {
    try expectRefused(.threaded);
}

test "transport: nothing listening closes promptly with \"Connection refused\" (polled)" {
    try expectRefused(.polled);
}

// ─── SIGPIPE ────────────────────────────────────────────────────────────────

// After a reset the next write fails with EPIPE — here the close frame the
// transport sends on its way down, plus whatever the app queued. Without
// SO_NOSIGPIPE / MSG_NOSIGNAL that write raised SIGPIPE, whose default action
// ends the process (exit 141).
test "transport: writing to a peer that reset the connection does not raise SIGPIPE" {
    // Zig's start code swallows SIGPIPE with a no-op handler. Put the default
    // back, so a raised SIGPIPE kills this binary the way it kills an app.
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.PIPE, &dfl, &old);
    defer posix.sigaction(posix.SIG.PIPE, &old, null);

    const payload = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');

    for ([_]Mode{ .threaded, .polled }) |mode| {
        c.colyseus_ws_set_polled(mode == .polled);
        defer c.colyseus_ws_set_polled(false);
        const pump = mode == .polled;

        var peer: Peer = undefined;
        try peer.start(.ip4);
        defer peer.stop();

        var rec: Rec = .{};
        const t = try connect(&rec, "127.0.0.1", peer.listener.port);
        defer c.colyseus_transport_destroy(t);
        try testing.expect(waitUntil(&rec, isOpen, pump, 3000));

        peer.act(.reset);
        std.Thread.sleep(50 * ms); // let the RST land first
        for (0..64) |_| c.colyseus_transport_send(t, payload.ptr, payload.len);

        // still alive, and the drop was reported
        try testing.expect(waitUntil(&rec, isClosed, pump, 3000));
    }
}

// ─── polled vs threaded ─────────────────────────────────────────────────────

const Poller = struct {
    rec: *Rec,
    tid: Tid = 0,
    opened: bool = false,

    fn run(self: *Poller) void {
        self.tid = std.Thread.getCurrentId();
        self.rec.want_tid.store(self.tid, .seq_cst);
        self.opened = waitUntil(self.rec, isOpen, true, 3000);
    }
};

// Threaded mode decoded state on the transport thread, racing the game's
// main-thread reads (a Godot client segfaulted in find_slot after minutes of
// play). Polled mode must leave nothing running on its own.
test "transport: polled mode starts no thread and delivers only inside colyseus_ws_poll, on its caller" {
    c.colyseus_ws_set_polled(true);
    defer c.colyseus_ws_set_polled(false);

    var peer: Peer = undefined;
    try peer.start(.ip4);
    defer peer.stop();

    var rec: Rec = .{};
    const t = try connect(&rec, "127.0.0.1", peer.listener.port);
    defer c.colyseus_transport_destroy(t);
    try testing.expect(impl(t).polled);
    try testing.expect(impl(t).tick_thread == null);

    // The mode is fixed at connect: flipping it back must not strand this socket.
    c.colyseus_ws_set_polled(false);

    // Unpolled, the socket never even sends its upgrade request.
    std.Thread.sleep(200 * ms);
    try testing.expectEqual(@as(u32, 0), rec.total());
    try testing.expect(!peer.upgraded.load(.seq_cst));

    // Callbacks follow whichever thread polls: a helper thread first...
    var poller: Poller = .{ .rec = &rec };
    const thread = try std.Thread.spawn(.{}, Poller.run, .{&poller});
    thread.join();
    try testing.expect(poller.opened);

    // ...nothing while nobody polls...
    peer.act(.frame);
    std.Thread.sleep(200 * ms);
    try testing.expectEqual(@as(u32, 0), rec.messages.load(.seq_cst));

    // ...then this one.
    rec.want_tid.store(std.Thread.getCurrentId(), .seq_cst);
    try testing.expect(waitUntil(&rec, hasMessage, true, 3000));
    peer.act(.close_frame);
    try testing.expect(waitUntil(&rec, isClosed, true, 3000));
    try testing.expectEqual(@as(c_int, 1000), rec.close_code.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), rec.wrong_thread.load(.seq_cst));
}

test "transport: threaded mode delivers from its own tick thread, and poll leaves it alone" {
    c.colyseus_ws_set_polled(false);

    var peer: Peer = undefined;
    try peer.start(.ip4);
    defer peer.stop();

    var rec: Rec = .{};
    rec.forbid_tid.store(std.Thread.getCurrentId(), .seq_cst);
    const t = try connect(&rec, "127.0.0.1", peer.listener.port);
    defer c.colyseus_transport_destroy(t);
    try testing.expect(!impl(t).polled);
    try testing.expect(impl(t).tick_thread != null);

    // the waits poll: a poll on this thread must not tick a threaded socket
    try testing.expect(waitUntil(&rec, isOpen, true, 3000));
    peer.act(.frame);
    try testing.expect(waitUntil(&rec, hasMessage, true, 3000));
    peer.act(.close_frame);
    try testing.expect(waitUntil(&rec, isClosed, true, 3000));
    try testing.expectEqual(@as(c_int, 1000), rec.close_code.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), rec.wrong_thread.load(.seq_cst));
}

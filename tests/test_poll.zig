// Offline checks of the polled runtime — colyseus_set_polled(true) with
// colyseus_poll() as the only driver:
//   - a matchmaking result waits for the poll and runs on the polling thread
//   - a colyseus_poll() from inside a callback it dispatched is a no-op
//   - a send from the polling thread leaves at once; from any other thread it
//     waits for the next poll
//   - a latency probe reports on the polling thread
//
// The peers are a refused port or the in-process WebSocket peer
// (ws_peer.zig), so no server is needed. POSIX only, like test_transport.
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus.h");
});

const ws_peer = @import("ws_peer.zig");
const Peer = ws_peer.Peer;

const ms = std.time.ns_per_ms;
const Tid = std.Thread.Id;

// ─── where callbacks may run ────────────────────────────────────────────────

/// Every callback must run on the thread that polls, inside a pump().
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
        std.Thread.sleep(2 * ms);
    }
}

// ─── matchmaking against a refused port ─────────────────────────────────────

const Mm = struct {
    var errors: std.atomic.Value(u32) = .init(0);
    var successes: std.atomic.Value(u32) = .init(0);
    var depth: std.atomic.Value(u32) = .init(0);
    var nested: std.atomic.Value(u32) = .init(0);
    var poll_inside: bool = false;

    fn reset() void {
        errors.store(0, .seq_cst);
        successes.store(0, .seq_cst);
        depth.store(0, .seq_cst);
        nested.store(0, .seq_cst);
        poll_inside = false;
    }

    fn onSuccess(_: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = successes.fetchAdd(1, .seq_cst);
    }

    fn onError(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
        if (depth.fetchAdd(1, .seq_cst) > 0) _ = nested.fetchAdd(1, .seq_cst);
        if (poll_inside) c.colyseus_poll();
        _ = depth.fetchSub(1, .seq_cst);
        _ = errors.fetchAdd(1, .seq_cst);
    }

    fn oneError() bool {
        return errors.load(.seq_cst) >= 1;
    }
    fn twoErrors() bool {
        return errors.load(.seq_cst) >= 2;
    }
};

const Refused = struct {
    settings: [*c]c.colyseus_settings_t,
    client: [*c]c.colyseus_client_t,

    fn open() !Refused {
        var port_buf: [8]u8 = undefined;
        const port = try std.fmt.bufPrintZ(&port_buf, "{d}", .{try ws_peer.freePort()});
        const settings = c.colyseus_settings_create();
        c.colyseus_settings_set_address(settings, "127.0.0.1");
        c.colyseus_settings_set_port(settings, port.ptr);
        const client = c.colyseus_client_create(settings);
        if (client == null) return error.OutOfMemory;
        return .{ .settings = settings, .client = client };
    }

    fn join(self: Refused) void {
        c.colyseus_client_join_or_create(self.client, "test_room", "{}", Mm.onSuccess, Mm.onError, null);
    }

    fn close(self: Refused) void {
        c.colyseus_client_free(self.client);
        c.colyseus_settings_free(self.settings);
    }
};

// The HTTP worker ran on_success/on_error itself, so a join callback — and
// the room it builds — raced the game loop.
test "poll: a matchmaking result waits for colyseus_poll and runs on its caller" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();
    Mm.reset();

    const mm = try Refused.open();
    defer mm.close();
    mm.join();

    // a refused request settles on the worker well within this
    std.Thread.sleep(500 * ms);
    try testing.expectEqual(@as(u32, 0), Mm.errors.load(.seq_cst));

    try testing.expect(pollUntil(Mm.oneError, 3000));
    try testing.expectEqual(@as(u32, 1), Mm.errors.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Mm.successes.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

test "poll: a colyseus_poll from inside a callback it dispatched is a no-op" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();
    Mm.reset();

    const mm = try Refused.open();
    defer mm.close();
    mm.join();
    mm.join();
    std.Thread.sleep(500 * ms); // both results queued

    // the first callback polls; the second result must not run inside it
    Mm.poll_inside = true;
    try testing.expect(pollUntil(Mm.twoErrors, 3000));
    try testing.expectEqual(@as(u32, 0), Mm.nested.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

// ─── send flush against the in-process peer ─────────────────────────────────

const Opens = struct {
    var opened: std.atomic.Value(u32) = .init(0);

    fn onOpen(_: ?*anyopaque) callconv(.c) void {
        aff.seen();
        _ = opened.fetchAdd(1, .seq_cst);
    }
    fn onMessage(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
    }
    fn onClose(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    fn onError(_: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        aff.seen();
    }

    fn isOpen() bool {
        return opened.load(.seq_cst) > 0;
    }
};

/// A polled transport to `peer`, opened by polling this thread.
fn openPolled(peer: *Peer) ![*c]c.colyseus_transport_t {
    Opens.opened.store(0, .seq_cst);
    var ev: c.colyseus_transport_events_t = .{
        .on_open = Opens.onOpen,
        .on_message = Opens.onMessage,
        .on_close = Opens.onClose,
        .on_error = Opens.onError,
        .userdata = null,
    };
    const t = c.colyseus_websocket_transport_create(&ev);
    if (t == null) return error.OutOfMemory;
    var buf: [64]u8 = undefined;
    c.colyseus_transport_connect(t, (try std.fmt.bufPrintZ(&buf, "ws://127.0.0.1:{d}", .{peer.listener.port})).ptr);
    if (!pollUntil(Opens.isOpen, 3000)) {
        c.colyseus_transport_destroy(t);
        return error.NeverOpened;
    }
    return t;
}

/// Waits for the peer to have `n` frames WITHOUT polling.
fn peerGets(peer: *Peer, n: u32, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (peer.received.load(.seq_cst) < n) {
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(2 * ms);
    }
    return true;
}

// Queued sends left on the NEXT poll: an input sampled and sent this frame
// reached the server a frame late.
test "poll: a send from the polling thread leaves without another poll" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();

    var peer: Peer = undefined;
    try peer.start(.ip4);
    defer peer.stop();

    const t = try openPolled(&peer);
    defer c.colyseus_transport_destroy(t);

    c.colyseus_transport_send(t, "input", 5);
    try testing.expect(peerGets(&peer, 1, 1000));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

fn sendFromHelper(t: [*c]c.colyseus_transport_t) void {
    c.colyseus_transport_send(t, "late", 4);
}

test "poll: a send from any other thread waits for the next poll" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();

    var peer: Peer = undefined;
    try peer.start(.ip4);
    defer peer.stop();

    const t = try openPolled(&peer);
    defer c.colyseus_transport_destroy(t);

    const helper = try std.Thread.spawn(.{}, sendFromHelper, .{t});
    helper.join();
    try testing.expect(!peerGets(&peer, 1, 200));

    pump();
    try testing.expect(peerGets(&peer, 1, 1000));
}

// ─── latency ────────────────────────────────────────────────────────────────

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

// The probe's coordinator thread reported the result.
test "poll: a latency probe reports on the polling thread" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);
    aff.begin();
    Latency.done.store(0, .seq_cst);

    var peer: Peer = undefined;
    try peer.startWith(.ip4, true); // echoes the PING back as the pong
    defer peer.stop();

    var buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrintZ(&buf, "ws://127.0.0.1:{d}", .{peer.listener.port});
    c.colyseus_get_latency(endpoint.ptr, null, Latency.onResult, null);

    // nothing drives the probe but the poll
    std.Thread.sleep(200 * ms);
    try testing.expect(!peer.upgraded.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), Latency.done.load(.seq_cst));

    try testing.expect(pollUntil(Latency.settled, 3000));
    try testing.expect(Latency.ok.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), Latency.done.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), aff.wrong.load(.seq_cst));
}

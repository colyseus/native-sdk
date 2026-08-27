// WSS (TLS) transport verification tests.
//
// Drives the WebSocket transport directly (no matchmaking) against a self-signed
// wss:// echo server (tests/tls/wss-echo-server.mjs), so it can validate cert
// verification in isolation:
//   - a trusted CA supplied via settings -> handshake succeeds (this is the #24
//     regression: the settings/override CA must actually be honored, not shadowed)
//   - bundled roots alone, or a wrong CA -> verification fails, no open
//   - tls_skip_verification -> opens regardless
//
// Requires the echo server on 127.0.0.1:2569 with certs from gen-certs.sh.
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/transport.h");
    @cInclude("colyseus/websocket_transport.h");
    @cInclude("colyseus/settings.h");
});

const URL = "wss://127.0.0.1:2569";

var g_opened = std.atomic.Value(bool).init(false);
var g_closed = std.atomic.Value(bool).init(false);
var g_errored = std.atomic.Value(bool).init(false);
var g_echoed = std.atomic.Value(u32).init(0);

fn reset() void {
    g_opened.store(false, .seq_cst);
    g_closed.store(false, .seq_cst);
    g_errored.store(false, .seq_cst);
    g_echoed.store(0, .seq_cst);
}

fn onOpen(_: ?*anyopaque) callconv(.c) void {
    g_opened.store(true, .seq_cst);
}
fn onMessage(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
    _ = g_echoed.fetchAdd(1, .seq_cst);
}
fn onClose(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    g_closed.store(true, .seq_cst);
}
fn onError(_: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    g_errored.store(true, .seq_cst);
}

fn makeEvents() c.colyseus_transport_events_t {
    return .{
        .on_open = onOpen,
        .on_message = onMessage,
        .on_close = onClose,
        .on_error = onError,
        .userdata = null,
    };
}

fn opened() bool {
    return g_opened.load(.seq_cst);
}
fn echoed() bool {
    return g_echoed.load(.seq_cst) > 0;
}
fn closed() bool {
    return g_closed.load(.seq_cst);
}
fn failed() bool {
    return g_closed.load(.seq_cst) or g_errored.load(.seq_cst);
}

// Skip rather than fail when the echo server isn't there.
fn connectOrSkip(ev: *const c.colyseus_transport_events_t, settings: *c.colyseus_settings_t) ![*c]c.colyseus_transport_t {
    const transport = c.colyseus_websocket_transport_create(ev);
    c.colyseus_websocket_connect_with_settings(transport, URL, settings);
    if (!pollUntil(opened, 8 * std.time.ns_per_s)) {
        c.colyseus_transport_destroy(transport);
        return error.SkipZigTest;
    }
    return transport;
}

fn pollUntil(condition: anytype, deadline_ns: u64) bool {
    const poll_interval = 10 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < deadline_ns) : (elapsed += poll_interval) {
        if (condition()) return true;
        std.Thread.sleep(poll_interval);
    }
    return false;
}

// Read a PEM file into a NUL-terminated buffer. Length returned includes the
// terminator, as colyseus_settings_set_ca_certificates expects. Caller frees.
fn loadPem(path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const buf = try testing.allocator.alloc(u8, size + 1);
    _ = try file.readAll(buf[0..size]);
    buf[size] = 0;
    return buf;
}

fn makeSettings(ca_pem: ?[]const u8, skip_verify: bool) *c.colyseus_settings_t {
    const s = c.colyseus_settings_create();
    c.colyseus_settings_set_address(s, "127.0.0.1");
    c.colyseus_settings_set_port(s, "2569");
    c.colyseus_settings_set_secure(s, true);
    s.*.tls_skip_verification = skip_verify;
    if (ca_pem) |pem| c.colyseus_settings_set_ca_certificates(s, pem.ptr, pem.len);
    return s;
}

test "tls: trusted CA via settings is honored -> handshake succeeds + echo" {
    reset();
    const ca = try loadPem("tests/tls/ca.pem");
    defer testing.allocator.free(ca);
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);

    var ev = makeEvents();
    const transport = c.colyseus_websocket_transport_create(&ev);
    defer c.colyseus_transport_destroy(transport);

    c.colyseus_websocket_connect_with_settings(transport, URL, settings);
    try testing.expect(pollUntil(opened, 8 * std.time.ns_per_s));

    // Data round-trips over the verified TLS connection.
    c.colyseus_transport_send(transport, "ping", 4);
    try testing.expect(pollUntil(echoed, 3 * std.time.ns_per_s));
}

test "tls: wrong CA -> verification fails, never opens" {
    reset();
    const ca = try loadPem("tests/tls/other-ca.pem");
    defer testing.allocator.free(ca);
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);

    var ev = makeEvents();
    const transport = c.colyseus_websocket_transport_create(&ev);
    defer c.colyseus_transport_destroy(transport);

    c.colyseus_websocket_connect_with_settings(transport, URL, settings);
    try testing.expect(pollUntil(failed, 8 * std.time.ns_per_s));
    try testing.expect(!opened());
}

test "tls: bundled roots alone do not trust the self-signed server" {
    reset();
    // No override CA, verification on: only bundled Mozilla + system roots apply.
    const settings = makeSettings(null, false);
    defer c.colyseus_settings_free(settings);

    var ev = makeEvents();
    const transport = c.colyseus_websocket_transport_create(&ev);
    defer c.colyseus_transport_destroy(transport);

    c.colyseus_websocket_connect_with_settings(transport, URL, settings);
    try testing.expect(pollUntil(failed, 8 * std.time.ns_per_s));
    try testing.expect(!opened());
}

test "tls: tls_skip_verification opens without any trusted CA" {
    reset();
    const settings = makeSettings(null, true);
    defer c.colyseus_settings_free(settings);

    var ev = makeEvents();
    const transport = c.colyseus_websocket_transport_create(&ev);
    defer c.colyseus_transport_destroy(transport);

    c.colyseus_websocket_connect_with_settings(transport, URL, settings);
    try testing.expect(pollUntil(opened, 8 * std.time.ns_per_s));
}

// ─── teardown ───────────────────────────────────────────────────────────────

// Tears the transport down from another thread while the tick thread is inside
// mbedtls_ssl_read — the window ws_close_impl's join-before-free exists to
// close. Reverting that ordering fails this in signal 6.
//
// The saturation is the load-bearing part: on a quiet socket the tick thread
// sleeps 10 ms out of every 10 ms, so a teardown lands between reads and the
// test passes against the bug.
test "tls: destroy while the reader is busy joins before it frees" {
    const rounds = 20;
    const frames = 128;
    const frame_bytes = 16 * 1024;   // frames * frame_bytes = 2 MB of echo

    const ca = try loadPem("tests/tls/ca.pem");
    defer testing.allocator.free(ca);

    const payload = try testing.allocator.alloc(u8, frame_bytes);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');

    // Loop-invariant: the transport copies the events struct on create.
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);
    var ev = makeEvents();

    for (0..rounds) |_| {
        reset();
        const transport = try connectOrSkip(&ev, settings);

        // Queued, not sent: the tick thread flushes, so it is saturated in
        // both directions by the time the first echo comes back.
        for (0..frames) |_| {
            c.colyseus_transport_send(transport, payload.ptr, payload.len);
        }

        _ = pollUntil(echoed, 3 * std.time.ns_per_s);
        c.colyseus_transport_destroy(transport);
    }
}

// Against the bug the app thread queued straight into the wslay context the
// tick thread drains. Its queue is a singly linked list with a tail pointer; a
// push interleaved with the pop of the last element either orphans the pushed
// message or leaves `tail` dangling, after which every later send vanishes
// (wslay asserts on that in Debug). It only bites when the queue is near
// empty, so the test reaches into the impl to hold it there: an echo-count
// throttle misses the window, the echo arrives after the pop.
const send_rounds = 3;
const sends_per_round: u32 = 20000;
fn allEchoed() bool {
    return g_echoed.load(.seq_cst) >= sends_per_round;
}

test "tls: every send from the app thread reaches the wire while the tick thread drains" {
    const ca = try loadPem("tests/tls/ca.pem");
    defer testing.allocator.free(ca);
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);
    var ev = makeEvents();
    const payload = [_]u8{ 'p', 'r', 'o', 'b', 'e' };

    for (0..send_rounds) |round| {
        reset();
        const transport = try connectOrSkip(&ev, settings);

        const impl: *c.colyseus_ws_transport_data_t = @ptrCast(@alignCast(transport.*.impl_data));
        var prng = std.Random.DefaultPrng.init(round);
        const rnd = prng.random();
        var i: u32 = 0;
        while (i < sends_per_round) : (i += 1) {
            while (c.wslay_event_get_queued_msg_count(impl.wslay_ctx) > 1) std.atomic.spinLoopHint();
            // jitter the push so it sweeps the pop's window
            const jitter = rnd.uintLessThan(u32, 400);
            var spin: u32 = 0;
            while (spin < jitter) : (spin += 1) std.atomic.spinLoopHint();
            c.colyseus_transport_send(transport, &payload, payload.len);
        }

        _ = pollUntil(allEchoed, 10 * std.time.ns_per_s);
        c.colyseus_transport_destroy(transport);
        try testing.expectEqual(sends_per_round, g_echoed.load(.seq_cst));
    }
}

// A remote/handshake failure closes from the tick thread, so on_close fires
// there; destroying the transport in that handler is a normal thing to do.
// Against the bug the tick thread then touches the freed struct. glibc trips
// on the resulting double free; macOS's xzone malloc zeroes freed memory and
// stays silent, so verify there under Guard Malloc:
//   DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib .zig-cache/o/<hash>/test
fn onCloseDestroy(_: c_int, _: [*c]const u8, ud: ?*anyopaque) callconv(.c) void {
    const transport: [*c]c.colyseus_transport_t = @ptrCast(@alignCast(ud));
    c.colyseus_transport_destroy(transport);
    g_closed.store(true, .seq_cst);
}

test "tls: destroying the transport from on_close on the tick thread" {
    const other = try loadPem("tests/tls/other-ca.pem");
    defer testing.allocator.free(other);
    const settings = makeSettings(other, false);
    defer c.colyseus_settings_free(settings);
    var ev = makeEvents();
    ev.on_close = onCloseDestroy;

    for (0..3) |_| {
        reset();
        const transport = c.colyseus_websocket_transport_create(&ev);
        transport.*.events.userdata = transport;
        // verification fails on the tick thread -> deferred close -> on_close there
        c.colyseus_websocket_connect_with_settings(transport, URL, settings);
        try testing.expect(pollUntil(closed, 8 * std.time.ns_per_s));
        // a detached thread's exit is unobservable: give a stale touch time to trip
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

// on_message fires from inside wslay's recv, mid-tick. A destroy there must
// leave the loop to finish the iteration and free on its way out, and end the
// callbacks: no on_close after the app said it is done.
fn onMessageDestroy(_: [*c]const u8, _: usize, ud: ?*anyopaque) callconv(.c) void {
    const transport: [*c]c.colyseus_transport_t = @ptrCast(@alignCast(ud));
    c.colyseus_transport_destroy(transport);
    _ = g_echoed.fetchAdd(1, .seq_cst);
}

test "tls: destroying the transport from on_message on the tick thread" {
    const ca = try loadPem("tests/tls/ca.pem");
    defer testing.allocator.free(ca);
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);
    var ev = makeEvents();
    ev.on_message = onMessageDestroy;

    for (0..3) |_| {
        reset();
        const transport = c.colyseus_websocket_transport_create(&ev);
        transport.*.events.userdata = transport;
        c.colyseus_websocket_connect_with_settings(transport, URL, settings);
        if (!pollUntil(opened, 8 * std.time.ns_per_s)) {
            c.colyseus_transport_destroy(transport);
            return error.SkipZigTest;
        }
        c.colyseus_transport_send(transport, "x", 1);
        try testing.expect(pollUntil(echoed, 8 * std.time.ns_per_s));
        // the loop finishes its iteration and frees; nothing observable but a
        // crash, and the callbacks must have ended
        std.Thread.sleep(100 * std.time.ns_per_ms);
        try testing.expect(!g_closed.load(.seq_cst));
    }
}

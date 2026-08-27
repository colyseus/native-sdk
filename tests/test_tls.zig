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
var g_echoed = std.atomic.Value(bool).init(false);

fn reset() void {
    g_opened.store(false, .seq_cst);
    g_closed.store(false, .seq_cst);
    g_errored.store(false, .seq_cst);
    g_echoed.store(false, .seq_cst);
}

fn onOpen(_: ?*anyopaque) callconv(.c) void {
    g_opened.store(true, .seq_cst);
}
fn onMessage(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
    g_echoed.store(true, .seq_cst);
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
    return g_echoed.load(.seq_cst);
}
fn failed() bool {
    return g_closed.load(.seq_cst) or g_errored.load(.seq_cst);
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
        const transport = c.colyseus_websocket_transport_create(&ev);
        c.colyseus_websocket_connect_with_settings(transport, URL, settings);
        if (!pollUntil(opened, 8 * std.time.ns_per_s)) {
            c.colyseus_transport_destroy(transport);
            return error.SkipZigTest;
        }

        // Queued, not sent: the tick thread flushes, so it is saturated in
        // both directions by the time the first echo comes back.
        for (0..frames) |_| {
            c.colyseus_transport_send(transport, payload.ptr, payload.len);
        }

        _ = pollUntil(echoed, 3 * std.time.ns_per_s);
        c.colyseus_transport_destroy(transport);
    }
}

// The app thread queues on the same wslay context the tick thread drains. Its
// queue is a singly linked list with a tail pointer; a push interleaved with
// the pop of the last element either orphans the pushed message or leaves
// `tail` dangling, after which every later send vanishes (wslay asserts on
// that in Debug). Only bites when the queue is near empty, so keep it there.
var g_echo_count = std.atomic.Value(u32).init(0);
fn onMessageCount(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
    _ = g_echo_count.fetchAdd(1, .seq_cst);
}
var g_want: u32 = 0;
fn allEchoed() bool {
    return g_echo_count.load(.seq_cst) >= g_want;
}

test "tls: every send from the app thread reaches the wire while the tick thread drains" {
    const rounds = 5;
    const sends: u32 = 20000;

    const ca = try loadPem("tests/tls/ca.pem");
    defer testing.allocator.free(ca);
    const settings = makeSettings(ca, false);
    defer c.colyseus_settings_free(settings);

    var ev = makeEvents();
    ev.on_message = onMessageCount;
    const payload = [_]u8{ 'p', 'r', 'o', 'b', 'e' };

    for (0..rounds) |round| {
        reset();
        g_echo_count.store(0, .seq_cst);
        g_want = sends;
        const transport = c.colyseus_websocket_transport_create(&ev);
        c.colyseus_websocket_connect_with_settings(transport, URL, settings);
        if (!pollUntil(opened, 8 * std.time.ns_per_s)) {
            c.colyseus_transport_destroy(transport);
            return error.SkipZigTest;
        }

        const impl: *c.colyseus_ws_transport_data_t = @ptrCast(@alignCast(transport.*.impl_data));
        var prng = std.Random.DefaultPrng.init(round);
        const rnd = prng.random();
        var i: u32 = 0;
        while (i < sends) : (i += 1) {
            // keep the queue at <=2 so almost every pop is a last-element pop,
            // and jitter the push so it sweeps the pop's window
            while (c.wslay_event_get_queued_msg_count(impl.wslay_ctx) > 1) std.atomic.spinLoopHint();
            const jitter = rnd.uintLessThan(u32, 400);
            var spin: u32 = 0;
            while (spin < jitter) : (spin += 1) std.atomic.spinLoopHint();
            c.colyseus_transport_send(transport, &payload, payload.len);
        }

        const ok = pollUntil(allEchoed, 10 * std.time.ns_per_s);
        const got = g_echo_count.load(.seq_cst);
        std.debug.print("round {d}: sent={d} echoed={d}{s}\n", .{ round, sends, got, if (ok) "" else "  <-- LOST" });
        c.colyseus_transport_destroy(transport);
        try testing.expectEqual(sends, got);
    }
}

// A remote/handshake failure closes from the tick thread, so on_close fires
// there; destroying the transport in that handler is a normal thing to do.
// Against the bug the tick thread then touches the freed struct. glibc trips
// on the resulting double free; macOS's xzone malloc zeroes freed memory and
// stays silent, so verify there under Guard Malloc:
//   DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib .zig-cache/o/<hash>/test
var g_close_target: ?*c.colyseus_transport_t = null;
var g_destroyed_in_close = std.atomic.Value(bool).init(false);
fn onCloseDestroy(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    c.colyseus_transport_destroy(g_close_target);
    g_destroyed_in_close.store(true, .seq_cst);
}
fn destroyedInClose() bool {
    return g_destroyed_in_close.load(.seq_cst);
}

test "tls: destroying the transport from on_close on the tick thread" {
    const other = try loadPem("tests/tls/other-ca.pem");
    defer testing.allocator.free(other);
    const settings = makeSettings(other, false);
    defer c.colyseus_settings_free(settings);
    var ev = makeEvents();
    ev.on_close = onCloseDestroy;

    for (0..4) |_| {
        reset();
        g_destroyed_in_close.store(false, .seq_cst);
        const transport = c.colyseus_websocket_transport_create(&ev);
        g_close_target = transport;
        // verification fails on the tick thread -> deferred close -> on_close there
        c.colyseus_websocket_connect_with_settings(transport, URL, settings);
        try testing.expect(pollUntil(destroyedInClose, 8 * std.time.ns_per_s));
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

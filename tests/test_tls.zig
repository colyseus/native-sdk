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

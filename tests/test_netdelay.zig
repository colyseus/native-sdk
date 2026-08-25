// Offline tests for the network-delay injector (src/network/net_delay.c) —
// a stack-fabricated transport + a scripted clock, no sockets. Covers the
// queue mechanics the live GMTL/GUT suites can't pin deterministically:
// deliver-at math, jitter monotonicity, close semantics, pointer restore.

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/net_delay.h");
    @cInclude("colyseus/transport.h");
    @cInclude("colyseus/room.h");
    @cInclude("colyseus/room_clock.h");
});

var NOW: f64 = 0;
fn scriptedNow() callconv(.c) f64 {
    return NOW;
}

// ── stub transport: record every delivery with its timestamp ────────────

const MAX_LOG = 64;
var sent_log: [MAX_LOG]u8 = undefined; // first payload byte
var sent_at: [MAX_LOG]f64 = undefined;
var sent_count: usize = 0;
var recv_log: [MAX_LOG]u8 = undefined;
var recv_at: [MAX_LOG]f64 = undefined;
var recv_count: usize = 0;
var close_code: c_int = 0;

fn stubSend(t: [*c]c.colyseus_transport_t, data: [*c]const u8, length: usize) callconv(.c) void {
    _ = t;
    if (length > 0 and sent_count < MAX_LOG) {
        sent_log[sent_count] = data[0];
        sent_at[sent_count] = NOW;
        sent_count += 1;
    }
}

fn stubClose(t: [*c]c.colyseus_transport_t, code: c_int, reason: [*c]const u8) callconv(.c) void {
    _ = t;
    _ = reason;
    close_code = code;
}

fn roomOnMessage(data: [*c]const u8, length: usize, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (length > 0 and recv_count < MAX_LOG) {
        recv_log[recv_count] = data[0];
        recv_at[recv_count] = NOW;
        recv_count += 1;
    }
}

fn roomOnOpen(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
}
fn roomOnClose(code: c_int, reason: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = reason;
    _ = userdata;
}
fn roomOnError(err: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = err;
    _ = userdata;
}

const Rig = struct {
    transport: c.colyseus_transport_t,
    room: c.colyseus_room_t,
};

var g_room_marker: u8 = 0; // its address doubles as the room userdata

fn makeRig(rig: *Rig) void {
    c.colyseus_room_clock_now_provider = scriptedNow;
    sent_count = 0;
    recv_count = 0;
    close_code = 0;
    rig.transport = std.mem.zeroes(c.colyseus_transport_t);
    rig.transport.send = stubSend;
    rig.transport.close = stubClose;
    rig.transport.events.on_message = roomOnMessage;
    rig.transport.events.on_open = roomOnOpen;
    rig.transport.events.on_close = roomOnClose;
    rig.transport.events.on_error = roomOnError;
    rig.transport.events.userdata = &g_room_marker;
    rig.room = std.mem.zeroes(c.colyseus_room_t);
    rig.room.transport = &rig.transport;
}

fn sendByte(rig: *Rig, byte: u8) void {
    const payload = [_]u8{byte};
    rig.transport.send.?(&rig.transport, &payload, 1);
}

fn recvByte(rig: *Rig, byte: u8) void {
    const payload = [_]u8{byte};
    rig.transport.events.on_message.?(&payload, 1, rig.transport.events.userdata);
}

test "netdelay: zero delay passes straight through" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 1000;
    c.colyseus_netdelay_set(&rig.room, 0, 0);
    defer c.colyseus_netdelay_unwrap(&rig.transport);

    sendByte(&rig, 1);
    recvByte(&rig, 2);
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqual(@as(i64, 0), c.colyseus_netdelay_in_flight());
}

// The configured number is a ROUND TRIP: each direction holds half of it, so
// 200 here means +100 outbound and +100 inbound.
test "netdelay: packets queue and deliver at now + half the round trip" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 1000;
    c.colyseus_netdelay_set(&rig.room, 200, 0);
    defer {
        c.colyseus_netdelay_set(&rig.room, 0, 0); // restore globals for later tests
        c.colyseus_netdelay_unwrap(&rig.transport);
    }

    sendByte(&rig, 1);
    recvByte(&rig, 2);
    try testing.expectEqual(@as(usize, 0), sent_count);
    try testing.expectEqual(@as(usize, 0), recv_count);
    try testing.expectEqual(@as(i64, 2), c.colyseus_netdelay_in_flight());

    NOW = 1050;
    c.colyseus_netdelay_pump();
    try testing.expectEqual(@as(usize, 0), sent_count); // not due yet
    try testing.expectEqual(@as(usize, 0), recv_count);

    NOW = 1100;
    c.colyseus_netdelay_pump();
    try testing.expectEqual(@as(usize, 1), sent_count);
    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqual(@as(u8, 1), sent_log[0]);
    try testing.expectEqual(@as(u8, 2), recv_log[0]);
    try testing.expectEqual(@as(i64, 0), c.colyseus_netdelay_in_flight());
}

test "netdelay: jitter never reorders — delivery order and times are monotonic" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 0;
    c.colyseus_netdelay_set(&rig.room, 50, 200); // heavy jitter vs light spacing
    defer {
        c.colyseus_netdelay_set(&rig.room, 0, 0);
        c.colyseus_netdelay_unwrap(&rig.transport);
    }

    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        NOW = @as(f64, @floatFromInt(i)) * 5;
        recvByte(&rig, i);
    }
    // pump in 1ms increments far past every possible deliver-at
    var t: f64 = 0;
    while (t < 500) : (t += 1) {
        NOW = t;
        c.colyseus_netdelay_pump();
    }
    try testing.expectEqual(@as(usize, 10), recv_count);
    i = 0;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(i, recv_log[i]); // enqueue order preserved
        if (i > 0) try testing.expect(recv_at[i] >= recv_at[i - 1]);
    }
}

test "netdelay: close drops both queues without delivering" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 0;
    c.colyseus_netdelay_set(&rig.room, 100, 0);
    defer {
        c.colyseus_netdelay_set(&rig.room, 0, 0);
        c.colyseus_netdelay_unwrap(&rig.transport);
    }

    sendByte(&rig, 1);
    recvByte(&rig, 2);
    try testing.expectEqual(@as(i64, 2), c.colyseus_netdelay_in_flight());

    // the close trampoline runs (as the WS thread would fire it)
    rig.transport.events.on_close.?(1000, "bye", rig.transport.events.userdata);

    NOW = 1000;
    c.colyseus_netdelay_pump();
    try testing.expectEqual(@as(usize, 0), sent_count);
    try testing.expectEqual(@as(usize, 0), recv_count);
    try testing.expectEqual(@as(i64, 0), c.colyseus_netdelay_in_flight());
}

test "netdelay: unwrap restores every pointer and the userdata" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 0;
    c.colyseus_netdelay_set(&rig.room, 0, 0);

    // armed: everything trampolined, userdata points at the wrap
    try testing.expect(rig.transport.send != stubSend);
    try testing.expect(rig.transport.events.on_message != roomOnMessage);
    try testing.expect(rig.transport.events.userdata != @as(?*anyopaque, &g_room_marker));

    c.colyseus_netdelay_unwrap(&rig.transport);
    try testing.expect(rig.transport.send == stubSend);
    try testing.expect(rig.transport.events.on_message == roomOnMessage);
    try testing.expect(rig.transport.events.on_open == roomOnOpen);
    try testing.expect(rig.transport.events.on_close == roomOnClose);
    try testing.expect(rig.transport.events.on_error == roomOnError);
    try testing.expect(rig.transport.events.userdata == @as(?*anyopaque, &g_room_marker));
}

test "netdelay: always_queue_inbound queues at zero delay, sends stay direct" {
    var rig: Rig = undefined;
    makeRig(&rig);
    NOW = 0;
    c.colyseus_netdelay_wrap(&rig.room, true);
    defer c.colyseus_netdelay_unwrap(&rig.transport);

    recvByte(&rig, 7);
    try testing.expectEqual(@as(usize, 0), recv_count); // queued, not direct
    try testing.expectEqual(@as(i64, 1), c.colyseus_netdelay_in_flight());
    sendByte(&rig, 8);
    try testing.expectEqual(@as(usize, 1), sent_count); // outbound unaffected

    c.colyseus_netdelay_pump(); // due immediately (zero delay)
    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqual(@as(u8, 7), recv_log[0]);
}

test "netdelay: drop closes with the reconnectable code" {
    var rig: Rig = undefined;
    makeRig(&rig);
    c.colyseus_netdelay_drop(&rig.room);
    try testing.expectEqual(@as(c_int, 4010), close_code);
}

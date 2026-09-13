// The GameMaker bridge against example-server (localhost:2567), driven the way
// GML drives it: doubles and strings in, events out of colyseus_gm_poll_event
// (what colyseus_process() loops on). The bridge runs the core polled, so the
// matchmaking result, every decode and every send happen on the thread that
// processes events — here, the test thread.
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus.h");
});

// ── bridge exports (no public header — the .yy is the contract) ─────────
extern fn colyseus_gm_client_create(endpoint: [*c]const u8) f64;
extern fn colyseus_gm_client_free(client: f64) void;
extern fn colyseus_gm_client_create_room(client: f64, room_name: [*c]const u8, options_json: [*c]const u8) f64;
extern fn colyseus_gm_poll_event() f64;
extern fn colyseus_gm_event_get_message() [*c]const u8;
extern fn colyseus_gm_room_send(room: f64, type: [*c]const u8, data: [*c]const u8) void;
extern fn colyseus_gm_room_leave(room: f64) void;
extern fn colyseus_gm_room_free(room: f64) void;
extern fn gm_room_ref_get(ref: c_int) ?*c.colyseus_room_t;

const EVENT_ROOM_JOIN: f64 = 1;
const EVENT_ROOM_MESSAGE: f64 = 3;
const EVENT_ROOM_LEAVE: f64 = 5;
const EVENT_CLIENT_ERROR: f64 = 6;

const ms = std.time.ns_per_ms;

const Seen = struct {
    var tid: std.Thread.Id = 0;
    var messages: std.atomic.Value(u32) = .init(0);
    var wrong: std.atomic.Value(u32) = .init(0);

    fn onAny(_: [*c]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
        if (std.Thread.getCurrentId() != tid) _ = wrong.fetchAdd(1, .seq_cst);
        _ = messages.fetchAdd(1, .seq_cst);
    }
};

/// One colyseus_process(): pop until the queue stays empty. True when an
/// event of `want` (and, for messages, of type `msg`) was among them.
fn process(want: f64, msg: ?[]const u8) bool {
    var found = false;
    while (true) {
        const t = colyseus_gm_poll_event();
        if (t == 0) return found;
        if (t == EVENT_CLIENT_ERROR) {
            std.debug.print("client error: {s}\n", .{std.mem.span(colyseus_gm_event_get_message())});
        }
        if (t != want) continue;
        if (msg) |m| {
            if (std.mem.eql(u8, std.mem.span(colyseus_gm_event_get_message()), m)) found = true;
        } else found = true;
    }
}

fn processUntil(want: f64, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        if (process(want, null)) return true;
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(5 * ms);
    }
}

// Threaded, the HTTP worker built the room and a socket thread decoded into
// it while GML read state; the netdelay wrap serialized frames but not the
// join callback, open/close, or a reconnect's give-up.
test "gm: matchmaking, decode and sends run on the GML thread" {
    const client = colyseus_gm_client_create("ws://localhost:2567");
    try testing.expect(client != 0);
    defer colyseus_gm_client_free(client);
    try testing.expect(c.colyseus_is_polled());

    const ref = colyseus_gm_client_create_room(client, "test_room", "{\"private\":true}");
    try testing.expect(ref != 0);
    const ref_i: c_int = @intFromFloat(ref);

    // matchmaking settles on its worker; its result waits for colyseus_process()
    std.Thread.sleep(500 * ms);
    try testing.expect(gm_room_ref_get(ref_i) == null);

    try testing.expect(processUntil(EVENT_ROOM_JOIN, 10_000));
    const room = gm_room_ref_get(ref_i) orelse return error.NoRoom;
    Seen.tid = std.Thread.getCurrentId();
    c.colyseus_room_on_message_any_encoded(room, Seen.onAny, null);

    colyseus_gm_room_send(ref, "echo", "\xa2hi"); // msgpack "hi"
    std.Thread.sleep(300 * ms);

    // nobody read the socket while GML wasn't processing...
    try testing.expectEqual(@as(i64, 0), c.colyseus_netdelay_in_flight());
    // ...and the send left at once, so the very next process has the reply
    try testing.expect(process(EVENT_ROOM_MESSAGE, "tagged_echo"));
    try testing.expect(Seen.messages.load(.seq_cst) >= 1);
    try testing.expectEqual(@as(u32, 0), Seen.wrong.load(.seq_cst));

    colyseus_gm_room_leave(ref);
    try testing.expect(processUntil(EVENT_ROOM_LEAVE, 5000));
    colyseus_gm_room_free(ref);
}

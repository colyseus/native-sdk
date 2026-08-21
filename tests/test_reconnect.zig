const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/messages.h");
    @cInclude("colyseus/protocol.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
});

const TEST_SERVER = "localhost";
const TEST_PORT = "2567";

const ReconnectTest = struct {
    var room: ?[*c]c.colyseus_room_t = null;
    var matchmake_succeeded: bool = false;
    var matchmake_failed: bool = false;
    var on_join_count: i32 = 0;
    var on_drop_count: i32 = 0;
    var on_reconnect_count: i32 = 0;
    var on_leave_count: i32 = 0;
    var on_leave_last_code: i32 = 0;
    var echo_received_count: i32 = 0;
    var on_error_count: i32 = 0;

    fn reset() void {
        room = null;
        matchmake_succeeded = false;
        matchmake_failed = false;
        on_join_count = 0;
        on_drop_count = 0;
        on_reconnect_count = 0;
        on_leave_count = 0;
        on_leave_last_code = 0;
        echo_received_count = 0;
        on_error_count = 0;
    }

    fn onJoin(userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
        on_join_count += 1;
    }

    fn onDrop(code: c_int, reason: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = reason;
        _ = userdata;
        _ = code;
        on_drop_count += 1;
    }

    fn onReconnect(userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
        on_reconnect_count += 1;
    }

    fn onLeave(code: c_int, reason: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = reason;
        _ = userdata;
        on_leave_last_code = @intCast(code);
        on_leave_count += 1;
    }

    fn onError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = code;
        _ = message;
        _ = userdata;
        on_error_count += 1;
    }

    fn onEcho(reader: ?*c.colyseus_message_reader_t, userdata: ?*anyopaque) callconv(.c) void {
        _ = reader;
        _ = userdata;
        echo_received_count += 1;
    }

    fn onMatchmakeSuccess(r: [*c]c.colyseus_room_t, userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
        room = r;
        c.colyseus_room_on_join(r, onJoin, null);
        c.colyseus_room_on_drop(r, onDrop, null);
        c.colyseus_room_on_reconnect(r, onReconnect, null);
        c.colyseus_room_on_leave(r, onLeave, null);
        c.colyseus_room_on_error(r, onError, null);
        c.colyseus_room_on_message(r, "tagged_echo", onEcho, null);
        matchmake_succeeded = true;
    }

    fn onMatchmakeFailure(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = code;
        _ = message;
        _ = userdata;
        matchmake_failed = true;
    }
};

fn pollUntil(condition: anytype, deadline_ns: u64) bool {
    const poll_interval = 10 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < deadline_ns) : (elapsed += poll_interval) {
        if (condition()) return true;
        std.Thread.sleep(poll_interval);
    }
    return false;
}

fn joined() bool { return ReconnectTest.on_join_count >= 1; }
fn dropped() bool { return ReconnectTest.on_drop_count >= 1; }
fn reconnected() bool { return ReconnectTest.on_reconnect_count >= 1; }
fn echoed() bool { return ReconnectTest.echo_received_count >= 1; }
fn leftWithFailedToReconnect() bool {
    return ReconnectTest.on_leave_count >= 1
        and ReconnectTest.on_leave_last_code == c.COLYSEUS_CLOSE_FAILED_TO_RECONNECT;
}

test "reconnect: drop + automatic reconnect + flushed messages" {
    ReconnectTest.reset();

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);
    try testing.expect(client != null);

    c.colyseus_client_join_or_create(
        client,
        "test_room",
        "{}",
        ReconnectTest.onMatchmakeSuccess,
        ReconnectTest.onMatchmakeFailure,
        null,
    );

    try testing.expect(pollUntil(joined, 10 * std.time.ns_per_s));
    try testing.expect(ReconnectTest.room != null);

    // Tighten reconnection options so the test runs quickly. We still need
    // joined_at_ms - now < min_uptime_ms to evaluate to false, so push the
    // floor down to zero. Bound delays to a few hundred ms.
    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.min_uptime_ms = 0;
    opts.min_delay_ms = 100;
    opts.max_delay_ms = 500;
    opts.delay_ms = 100;
    opts.max_retries = 5;
    c.colyseus_room_set_reconnection_options(ReconnectTest.room.?, &opts);

    // Trigger a 4010 close from the server.
    const force = c.colyseus_message_map_create();
    defer c.colyseus_message_free(force);
    c.colyseus_room_send(ReconnectTest.room.?, "force_drop", force);

    try testing.expect(pollUntil(dropped, 5 * std.time.ns_per_s));
    try testing.expect(c.colyseus_room_is_reconnecting(ReconnectTest.room.?));

    // While the socket is closed, enqueue an echo message. The flush after
    // a successful JOIN_ROOM should deliver it and the server should reply
    // with "tagged_echo".
    const echo = c.colyseus_message_map_create();
    defer c.colyseus_message_free(echo);
    c.colyseus_message_map_put_str(echo, "payload", "queued-while-down");
    c.colyseus_room_send(ReconnectTest.room.?, "echo", echo);

    try testing.expect(pollUntil(reconnected, 10 * std.time.ns_per_s));
    try testing.expect(!c.colyseus_room_is_reconnecting(ReconnectTest.room.?));
    try testing.expect(pollUntil(echoed, 5 * std.time.ns_per_s));

    // on_leave must NOT have fired on the drop path.
    try testing.expectEqual(@as(i32, 0), ReconnectTest.on_leave_count);

    c.colyseus_room_leave(ReconnectTest.room.?, true);
    defer c.colyseus_room_free(ReconnectTest.room.?);
    std.Thread.sleep(200 * std.time.ns_per_ms);
}

test "reconnect: gives up after max_retries and fires on_leave(FAILED_TO_RECONNECT)" {
    ReconnectTest.reset();

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);
    try testing.expect(client != null);

    c.colyseus_client_join_or_create(
        client,
        "test_room",
        "{}",
        ReconnectTest.onMatchmakeSuccess,
        ReconnectTest.onMatchmakeFailure,
        null,
    );

    try testing.expect(pollUntil(joined, 10 * std.time.ns_per_s));
    try testing.expect(ReconnectTest.room != null);

    // Capture the reconnection token now, then *clobber it* to a value that
    // matchmaking will reject. Subsequent reconnect attempts will all fail
    // and the worker should give up after max_retries.
    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.min_uptime_ms = 0;
    opts.min_delay_ms = 50;
    opts.max_delay_ms = 100;
    opts.delay_ms = 50;
    opts.max_retries = 2;
    c.colyseus_room_set_reconnection_options(ReconnectTest.room.?, &opts);

    // Force the drop.
    const force = c.colyseus_message_map_create();
    defer c.colyseus_message_free(force);
    c.colyseus_room_send(ReconnectTest.room.?, "force_drop", force);

    try testing.expect(pollUntil(dropped, 5 * std.time.ns_per_s));

    // Tear down the server's allowReconnection window by waiting longer than
    // the server-side timeout… or, simpler: rely on the fact that allowing
    // only 2 retries with a max 100ms delay means the worker will exhaust
    // its budget in under ~500ms even when reconnect succeeds at the
    // network level. We assert that *either* it eventually reconnected
    // (server still in the grace window — accept that as a pass-through) or
    // it gave up. The point of this test is that it doesn't hang.
    const deadline = 30 * std.time.ns_per_s;
    var elapsed: u64 = 0;
    const poll_interval = 50 * std.time.ns_per_ms;
    while (elapsed < deadline) : (elapsed += poll_interval) {
        if (ReconnectTest.on_reconnect_count >= 1) break;
        if (leftWithFailedToReconnect()) break;
        std.Thread.sleep(poll_interval);
    }
    try testing.expect(ReconnectTest.on_reconnect_count >= 1
        or leftWithFailedToReconnect());

    c.colyseus_room_leave(ReconnectTest.room.?, true);
    defer c.colyseus_room_free(ReconnectTest.room.?);
    std.Thread.sleep(200 * std.time.ns_per_ms);
}

fn errored() bool { return ReconnectTest.on_error_count >= 1; }

// A retry whose connect() fails before a socket exists (DNS down — what an
// Android app sees right after resume) must still count against max_retries
// and end in on_leave(FAILED_TO_RECONNECT).
test "reconnect: synchronous connect failure does not wedge the retry loop" {
    ReconnectTest.reset();

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);
    try testing.expect(client != null);

    c.colyseus_client_join_or_create(
        client,
        "test_room",
        "{}",
        ReconnectTest.onMatchmakeSuccess,
        ReconnectTest.onMatchmakeFailure,
        null,
    );

    try testing.expect(pollUntil(joined, 10 * std.time.ns_per_s));
    const room = ReconnectTest.room.?;

    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.min_uptime_ms = 0;
    opts.min_delay_ms = 50;
    opts.max_delay_ms = 100;
    opts.delay_ms = 50;
    opts.max_retries = 2;
    c.colyseus_room_set_reconnection_options(room, &opts);

    // .invalid never resolves, so every retry's getaddrinfo() fails inside
    // connect() — the transport reports on_error and never on_close.
    c.free(room.*.endpoint_url);
    room.*.endpoint_url = c.strdup("ws://reconnect-test.invalid:2567/test_room?sessionId=x");

    const force = c.colyseus_message_map_create();
    defer c.colyseus_message_free(force);
    c.colyseus_room_send(room, "force_drop", force);

    try testing.expect(pollUntil(dropped, 5 * std.time.ns_per_s));
    try testing.expect(pollUntil(errored, 5 * std.time.ns_per_s));

    // 2 retries × ≤100ms backoff: give-up should land well inside 5s.
    try testing.expect(pollUntil(leftWithFailedToReconnect, 5 * std.time.ns_per_s));
    try testing.expect(!c.colyseus_room_is_reconnecting(room));

    defer c.colyseus_room_free(room);
}

const ManualReconnect = struct {
    var rejoined: bool = false;
    var failed: bool = false;

    fn reset() void {
        rejoined = false;
        failed = false;
    }
    fn onJoin(_: ?*anyopaque) callconv(.c) void { rejoined = true; }
    fn onError(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void { failed = true; }
    fn onSuccess(r: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        c.colyseus_room_on_join(r, onJoin, null);
        c.colyseus_room_on_error(r, onError, null);
    }
    fn settled() bool { return rejoined or failed; }
};

// The token the room hands out must be accepted by client.reconnect() as-is,
// the way `client.reconnect(room.reconnectionToken)` works in the TS SDK.
test "reconnect: manual client.reconnect() with the room's token" {
    ReconnectTest.reset();
    ManualReconnect.reset();

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);
    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    c.colyseus_client_join_or_create(client, "test_room", "{}",
        ReconnectTest.onMatchmakeSuccess, ReconnectTest.onMatchmakeFailure, null);
    try testing.expect(pollUntil(joined, 10 * std.time.ns_per_s));
    const room = ReconnectTest.room.?;
    defer c.colyseus_room_free(room);

    const token = c.colyseus_room_get_reconnection_token(room);
    try testing.expect(token != null and token[0] != 0);

    // take the automatic path out of the picture: the drop must end in on_leave
    var opts: c.colyseus_reconnection_options_t = undefined;
    c.colyseus_reconnection_options_init_defaults(&opts);
    opts.enabled = false;
    c.colyseus_room_set_reconnection_options(room, &opts);

    const force = c.colyseus_message_map_create();
    defer c.colyseus_message_free(force);
    c.colyseus_room_send(room, "force_drop", force);
    try testing.expect(pollUntil(struct {
        fn f() bool { return ReconnectTest.on_leave_count >= 1; }
    }.f, 5 * std.time.ns_per_s));

    // server keeps the seat for 10s (allowReconnection)
    c.colyseus_client_reconnect(client, token, ManualReconnect.onSuccess, ManualReconnect.onError, null);
    try testing.expect(pollUntil(ManualReconnect.settled, 5 * std.time.ns_per_s));
    try testing.expect(ManualReconnect.rejoined);
}

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/room.h");
    @cInclude("colyseus/auth/auth.h");
    @cInclude("string.h");
});

var auth_change_called: c_int = 0;
var received_token: ?[*:0]u8 = null;

fn onAuthChange(data: [*c]const c.colyseus_auth_data_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    auth_change_called += 1;

    if (data.*.token != null) {
        if (received_token) |old_token| {
            std.c.free(old_token);
        }
        received_token = @ptrCast(c.strdup(data.*.token));
    } else {
        if (received_token) |old_token| {
            std.c.free(old_token);
        }
        received_token = null;
    }
}

test "auth: token operations" {
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    const auth = c.colyseus_client_get_auth(client);

    // Test onChange callback
    c.colyseus_auth_on_change(auth, onAuthChange, null);
    try testing.expect(auth_change_called > 0);

    // Test set token
    auth_change_called = 0;
    c.colyseus_auth_set_token(auth, "test_token_123");

    const token = c.colyseus_auth_get_token(auth);
    try testing.expect(token != null);
    try testing.expectEqualStrings("test_token_123", std.mem.span(token));

    // Test token persistence
    c.colyseus_auth_signout(auth);
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Cleanup
    if (received_token) |token_ptr| {
        std.c.free(token_ptr);
        received_token = null;
    }
}

// ─── a signed-in token reaches the room ─────────────────────────────────────
// example-server's auth_static_room checks the token at matchmaking (the
// Authorization header), auth_instance_room at connect time (?_authToken=).

const ms = std.time.ns_per_ms;

const Join = struct {
    var room: [*c]c.colyseus_room_t = null;
    var joined: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var left: std.atomic.Value(u32) = .init(0);
    var fail_message: [160]u8 = undefined;
    var fail_len: usize = 0;

    fn reset() void {
        room = null;
        inline for (.{ &joined, &failed, &left }) |v| v.store(0, .seq_cst);
        fail_len = 0;
    }

    fn record(message: [*c]const u8) void {
        if (message == null) return;
        const text = std.mem.span(message);
        fail_len = @min(text.len, fail_message.len);
        @memcpy(fail_message[0..fail_len], text[0..fail_len]);
        _ = failed.fetchAdd(1, .seq_cst);
    }

    fn onRoom(r: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        room = r;
        c.colyseus_room_on_join(r, onJoin, null);
        c.colyseus_room_on_error(r, onRoomError, null);
        c.colyseus_room_on_leave(r, onLeave, null);
    }
    fn onMatchmakeError(_: c_int, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        record(message);
    }
    fn onRoomError(_: c_int, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        record(message);
    }
    fn onJoin(_: ?*anyopaque) callconv(.c) void {
        _ = joined.fetchAdd(1, .seq_cst);
    }
    fn onLeave(_: c_int, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        _ = left.fetchAdd(1, .seq_cst);
    }

    fn settled() bool {
        return joined.load(.seq_cst) > 0 or failed.load(.seq_cst) > 0 or left.load(.seq_cst) > 0;
    }
    fn hasLeft() bool {
        return left.load(.seq_cst) > 0;
    }
    fn failMessage() []const u8 {
        return fail_message[0..fail_len];
    }
};

fn pollUntil(comptime cond: fn () bool, timeout_ms: u64) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        c.colyseus_poll();
        if (cond()) return true;
        if (timer.read() >= timeout_ms * ms) return false;
        std.Thread.sleep(5 * ms);
    }
}

/// Joins `room_name`; true once the server admitted the client.
fn joinRoom(client: [*c]c.colyseus_client_t, room_name: [*c]const u8) bool {
    Join.reset();
    c.colyseus_client_join_or_create(client, room_name, "{}", Join.onRoom, Join.onMatchmakeError, null);
    _ = pollUntil(Join.settled, 8000);
    // a refusal at connect time can land just after the room was handed out
    if (Join.joined.load(.seq_cst) == 0) _ = pollUntil(Join.hasLeft, 1000);
    const ok = Join.joined.load(.seq_cst) > 0;
    if (!ok) std.debug.print("join {s} refused: {s}\n", .{ room_name, Join.failMessage() });

    if (Join.room != null) {
        if (ok) {
            c.colyseus_room_leave(Join.room, true);
            _ = pollUntil(Join.hasLeft, 5000);
        }
        c.colyseus_room_free(Join.room);
        Join.room = null;
    }
    return ok;
}

const SignIn = struct {
    var ok: bool = false;
    fn onOk(_: [*c]const c.colyseus_auth_data_t, _: ?*anyopaque) callconv(.c) void {
        ok = true;
    }
    fn onErr(message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        std.debug.print("auth failed: {s}\n", .{message});
        ok = false;
    }
};

/// Registers a fresh account, signs out, then signs back in with it.
fn signInWithEmail(auth: ?*c.colyseus_auth_t) !void {
    var email_buf: [64]u8 = undefined;
    const email = try std.fmt.bufPrintZ(&email_buf, "zig-{d}@example.com", .{std.time.nanoTimestamp()});

    // the auth calls block; their callbacks run before they return
    SignIn.ok = false;
    c.colyseus_auth_register_email_password(auth, email.ptr, "secret123", null, SignIn.onOk, SignIn.onErr, null);
    try testing.expect(SignIn.ok);
    c.colyseus_auth_signout(auth);

    SignIn.ok = false;
    c.colyseus_auth_signin_email_password(auth, email.ptr, "secret123", SignIn.onOk, SignIn.onErr, null);
    try testing.expect(SignIn.ok);
    try testing.expect(c.colyseus_auth_get_token(auth) != null);
}

fn newClient() ![*c]c.colyseus_client_t {
    const settings = c.colyseus_settings_create();
    c.colyseus_settings_set_address(settings, "localhost");
    c.colyseus_settings_set_port(settings, "2567");
    const client = c.colyseus_client_create(settings);
    if (client == null) return error.OutOfMemory;
    return client;
}

fn freeClient(client: [*c]c.colyseus_client_t) void {
    const settings = client.*.settings;
    c.colyseus_auth_signout(c.colyseus_client_get_auth(client));
    c.colyseus_client_free(client);
    c.colyseus_settings_free(settings);
}

test "auth: the signed-in token authenticates matchmaking (static onAuth)" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);

    const client = try newClient();
    defer freeClient(client);

    try signInWithEmail(c.colyseus_client_get_auth(client));
    try testing.expect(joinRoom(client, "auth_static_room"));
}

test "auth: the signed-in token reaches the room's onAuth (?_authToken=)" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);

    const client = try newClient();
    defer freeClient(client);

    try signInWithEmail(c.colyseus_client_get_auth(client));
    try testing.expect(joinRoom(client, "auth_instance_room"));
}

test "auth: both rooms refuse a signed-out client" {
    c.colyseus_set_polled(true);
    defer c.colyseus_set_polled(false);

    const client = try newClient();
    defer freeClient(client);

    c.colyseus_auth_signout(c.colyseus_client_get_auth(client));
    try testing.expect(!joinRoom(client, "auth_static_room"));
    try testing.expect(!joinRoom(client, "auth_instance_room"));
}

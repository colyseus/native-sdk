// What colyseus_client_join_or_create() hands on_error when matchmaking
// fails, against a one-shot HTTP peer serving a canned response, so no server
// is needed. The code comes from the body: a server with
// matchMaker.controller.standardHttpStatus answers 404 for a 520
// (colyseus#999). POSIX only, like test_transport.
const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const c = @cImport({
    @cInclude("colyseus.h");
});

const ws_peer = @import("ws_peer.zig");

const ms = std.time.ns_per_ms;

/// Accepts one connection, reads its request, answers with `response`.
const Canned = struct {
    listener: ws_peer.Listener,
    response: []const u8,
    thread: ?std.Thread = null,

    fn open(response: []const u8) !Canned {
        return .{ .listener = try ws_peer.Listener.open(.ip4), .response = response };
    }

    fn serveInBackground(self: *Canned) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Closing the listener resets a request still in its backlog, so a
    /// client stuck waiting on one can be freed.
    fn stop(self: *Canned) void {
        if (self.listener.fd == -1) return;
        if (self.thread) |t| t.join();
        posix.close(self.listener.fd);
        self.listener.fd = -1;
    }

    fn run(self: *Canned) void {
        self.serve() catch |err| std.debug.print("canned peer: {s}\n", .{@errorName(err)});
    }

    fn serve(self: *Canned) !void {
        try waitReadable(self.listener.fd);
        const conn = try posix.accept(self.listener.fd, null, null, 0);
        defer posix.close(conn);

        // all of it: closing with unread bytes resets the connection
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (!requestComplete(buf[0..len])) {
            if (len == buf.len) return error.RequestTooLarge;
            try waitReadable(conn);
            const n = try posix.read(conn, buf[len..]);
            if (n == 0) return error.EndOfStream;
            len += n;
        }
        try ws_peer.writeAll(conn, self.response);
    }

    fn waitReadable(fd: posix.socket_t) !void {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 5000) == 0) return error.Timeout;
    }

    fn requestComplete(req: []const u8) bool {
        const head_end = (std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false) + 4;
        const name = "\r\ncontent-length:";
        const at = std.ascii.indexOfIgnoreCase(req[0..head_end], name) orelse return true;
        const value_end = std.mem.indexOfPos(u8, req, at + name.len, "\r\n").?;
        const body_len = std.fmt.parseInt(usize, std.mem.trim(u8, req[at + name.len .. value_end], " "), 10) catch return true;
        return req.len >= head_end + body_len;
    }
};

fn httpResponse(comptime status: []const u8, comptime content_type: []const u8, comptime body: []const u8) []const u8 {
    return "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Type: " ++ content_type ++ "\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n", .{body.len}) ++
        "Connection: close\r\n\r\n" ++ body;
}

const Outcome = struct {
    var done: std.atomic.Value(bool) = .init(false);
    var joined: bool = false;
    var code: c_int = 0;
    var message_buf: [128]u8 = undefined;
    var message: []const u8 = "";

    fn onSuccess(_: [*c]c.colyseus_room_t, _: ?*anyopaque) callconv(.c) void {
        joined = true;
        done.store(true, .seq_cst);
    }

    fn onError(error_code: c_int, text: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        code = error_code;
        const span: []const u8 = if (text != null) std.mem.span(text) else "";
        const n = @min(span.len, message_buf.len);
        @memcpy(message_buf[0..n], span[0..n]);
        message = message_buf[0..n];
        done.store(true, .seq_cst);
    }
};

/// Joins "my_room" against a peer that answers with `canned`.
fn joinAgainst(canned: []const u8) !void {
    Outcome.done.store(false, .seq_cst);
    Outcome.joined = false;
    Outcome.code = 0;
    Outcome.message = "";

    var peer = try Canned.open(canned);
    defer peer.stop();

    var port_buf: [8]u8 = undefined;
    const port = try std.fmt.bufPrintZ(&port_buf, "{d}", .{peer.listener.port});
    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);
    c.colyseus_settings_set_address(settings, "127.0.0.1");
    c.colyseus_settings_set_port(settings, port.ptr);
    // reads the stored auth token: on macOS, a fresh binary can sit on a keychain prompt
    const client = c.colyseus_client_create(settings);
    if (client == null) return error.OutOfMemory;
    defer c.colyseus_client_free(client);
    try peer.serveInBackground(); // its accept timeout starts now

    c.colyseus_client_join_or_create(client, "my_room", "{}", Outcome.onSuccess, Outcome.onError, null);
    var timer = try std.time.Timer.start();
    while (!Outcome.done.load(.seq_cst)) {
        if (timer.read() > 10_000 * ms) {
            peer.stop(); // before the deferred free, which joins the HTTP worker
            return error.Timeout;
        }
        std.Thread.sleep(2 * ms);
    }
    try testing.expect(!Outcome.joined);
}

test "matchmaking: a standard HTTP status reports the ErrorCode from the body" {
    try joinAgainst(httpResponse("404 Not Found", "application/json",
        \\{"code":520,"error":"provided room name \"my_room\" not defined"}
    ));
    try testing.expectEqual(@as(c_int, 520), Outcome.code);
    try testing.expectEqualStrings("provided room name \"my_room\" not defined", Outcome.message);
}

test "matchmaking: a custom code thrown from onAuth() arrives behind a 500" {
    try joinAgainst(httpResponse("500 Internal Server Error", "application/json",
        \\{"code":4000,"error":"banned"}
    ));
    try testing.expectEqual(@as(c_int, 4000), Outcome.code);
    try testing.expectEqualStrings("banned", Outcome.message);
}

test "matchmaking: a server sending the ErrorCode as the status still reports it" {
    try joinAgainst(httpResponse("520 Unknown", "application/json",
        \\{"code":520,"error":"provided room name \"my_room\" not defined"}
    ));
    try testing.expectEqual(@as(c_int, 520), Outcome.code);
}

test "matchmaking: a response without a code (e.g. from a proxy) reports the status" {
    try joinAgainst(httpResponse("502 Bad Gateway", "text/html", "<h1>502 Bad Gateway</h1>"));
    try testing.expectEqual(@as(c_int, 502), Outcome.code);
    try testing.expectEqualStrings("<h1>502 Bad Gateway</h1>", Outcome.message);
}

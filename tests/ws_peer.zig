// A loopback WebSocket peer for the offline transport suites: a minimal
// RFC 6455 upgrade responder on an ephemeral port, driven one command at a
// time. It also reads what the client sends, so a test can tell whether a
// frame left the client without asking the client.
//
// POSIX only (BSD sockets); build.zig skips its suites on Windows.
const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const ms = std.time.ns_per_ms;

pub const Family = enum { ip4, ip6 };

pub const Listener = struct {
    fd: posix.socket_t,
    port: u16,

    /// An ephemeral port on the loopback of one family only. Skips when the
    /// host has no IPv6 loopback.
    pub fn open(family: Family) !Listener {
        var addr = switch (family) {
            .ip4 => try std.net.Address.parseIp4("127.0.0.1", 0),
            .ip6 => try std.net.Address.parseIp6("::1", 0),
        };
        const fd = posix.socket(addr.any.family, posix.SOCK.STREAM, 0) catch |err| {
            if (family == .ip6) return skip("no IPv6 sockets on this host");
            return err;
        };
        errdefer posix.close(fd);
        posix.bind(fd, &addr.any, addr.getOsSockLen()) catch |err| {
            if (family == .ip6) return skip("no ::1 on this host");
            return err;
        };
        try posix.listen(fd, 8);
        var len = addr.getOsSockLen();
        try posix.getsockname(fd, &addr.any, &len);
        return .{ .fd = fd, .port = addr.getPort() };
    }
};

pub fn skip(why: []const u8) error{SkipZigTest} {
    std.debug.print("skip: {s}\n", .{why});
    return error.SkipZigTest;
}

/// A port nothing listens on (as of a moment ago).
pub fn freePort() !u16 {
    const l = try Listener.open(.ip4);
    posix.close(l.fd);
    return l.port;
}

/// Accepts one client, answers its upgrade, then runs the commands the test
/// hands it through `act`, one at a time — reading the client's frames in
/// between.
pub const Peer = struct {
    listener: Listener,
    cmd: std.atomic.Value(Cmd) = .init(.none),
    upgraded: std.atomic.Value(bool) = .init(false),
    /// Data frames received from the client.
    received: std.atomic.Value(u32) = .init(0),
    /// Answer every data frame with one of the same payload.
    echo: bool = false,
    thread: std.Thread = undefined,
    rx: [64 * 1024]u8 = undefined,
    rx_len: usize = 0,

    pub const Cmd = enum(u8) { none, frame, close_frame, reset, stop };

    pub fn start(self: *Peer, family: Family) !void {
        try self.startWith(family, false);
    }

    pub fn startWith(self: *Peer, family: Family, echo: bool) !void {
        self.* = .{ .listener = try Listener.open(family), .echo = echo };
        errdefer posix.close(self.listener.fd);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Returns once the peer has carried `cmd` out.
    pub fn act(self: *Peer, cmd: Cmd) void {
        self.cmd.store(cmd, .seq_cst);
        while (self.cmd.load(.seq_cst) == cmd) std.Thread.sleep(1 * ms);
    }

    pub fn stop(self: *Peer) void {
        self.cmd.store(.stop, .seq_cst);
        self.thread.join();
        posix.close(self.listener.fd);
    }

    fn ack(self: *Peer, cmd: Cmd) void {
        _ = self.cmd.cmpxchgStrong(cmd, .none, .seq_cst, .seq_cst);
    }

    fn stopping(self: *Peer) bool {
        return self.cmd.load(.seq_cst) == .stop;
    }

    fn run(self: *Peer) void {
        self.serve() catch |err| std.debug.print("peer: {s}\n", .{@errorName(err)});
        // keep acking, so a test that outlived its peer fails an assert, not hangs
        while (!self.stopping()) {
            const cmd = self.cmd.load(.seq_cst);
            if (cmd != .none) self.ack(cmd);
            std.Thread.sleep(1 * ms);
        }
    }

    fn serve(self: *Peer) !void {
        const conn = (try self.accept()) orelse return;
        var open = true;
        defer if (open) posix.close(conn);

        if (!try self.upgrade(conn)) return;
        self.upgraded.store(true, .seq_cst);

        while (true) {
            const cmd = self.cmd.load(.seq_cst);
            switch (cmd) {
                .none => {
                    if (!open) {
                        std.Thread.sleep(1 * ms);
                        continue;
                    }
                    self.readFrames(conn) catch |err| switch (err) {
                        error.EndOfStream => return, // the client went away
                        else => return err,
                    };
                    continue;
                },
                .stop => return,
                .frame => try writeAll(conn, &.{ 0x82, 2, 'h', 'i' }),
                .close_frame => try writeAll(conn, &.{ 0x88, 2, 0x03, 0xE8 }), // 1000
                .reset => {
                    // linger 0: close() sends RST instead of FIN
                    const Linger = extern struct { l_onoff: c_int, l_linger: c_int };
                    const lg: Linger = .{ .l_onoff = 1, .l_linger = 0 };
                    try posix.setsockopt(conn, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&lg));
                    posix.close(conn);
                    open = false;
                },
            }
            self.ack(cmd);
        }
    }

    /// Reads whatever the client sent within a millisecond.
    fn readFrames(self: *Peer, fd: posix.socket_t) !void {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 1) == 0) return;
        if (self.rx_len == self.rx.len) return error.FrameTooLarge;
        const got = posix.read(fd, self.rx[self.rx_len..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.EndOfStream,
            else => return err,
        };
        if (got == 0) return error.EndOfStream;
        self.rx_len += got;
        while (try self.takeFrame(fd)) {}
    }

    /// One complete client frame off the front of `rx`, or false.
    fn takeFrame(self: *Peer, fd: posix.socket_t) !bool {
        const b = self.rx[0..self.rx_len];
        if (b.len < 2) return false;
        const opcode = b[0] & 0x0f;
        var len: usize = b[1] & 0x7f;
        var off: usize = 2;
        if (len == 126) {
            if (b.len < 4) return false;
            len = std.mem.readInt(u16, b[2..4], .big);
            off = 4;
        } else if (len == 127) {
            if (b.len < 10) return false;
            len = @intCast(std.mem.readInt(u64, b[2..10], .big));
            off = 10;
        }
        const masked = b[1] & 0x80 != 0;
        const key_at = off;
        if (masked) off += 4;
        if (b.len < off + len) return false;

        const payload = b[off .. off + len];
        if (masked) {
            for (payload, 0..) |*byte, i| byte.* ^= b[key_at + i % 4];
        }
        if (opcode == 0x1 or opcode == 0x2) {
            if (self.echo) try writeFrame(fd, payload);
            _ = self.received.fetchAdd(1, .seq_cst);
        }

        const used = off + len;
        std.mem.copyForwards(u8, self.rx[0..], self.rx[used..self.rx_len]);
        self.rx_len -= used;
        return true;
    }

    fn accept(self: *Peer) !?posix.socket_t {
        var fds = [_]posix.pollfd{.{ .fd = self.listener.fd, .events = posix.POLL.IN, .revents = 0 }};
        while (!self.stopping()) {
            if (try posix.poll(&fds, 10) > 0) return try posix.accept(self.listener.fd, null, null, 0);
        }
        return null;
    }

    /// False when told to stop before the request arrived.
    fn upgrade(self: *Peer, fd: posix.socket_t) !bool {
        var buf: [2048]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            if (self.stopping()) return false;
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 10) == 0) continue;
            const got = try posix.read(fd, buf[n..]);
            if (got == 0) return error.EndOfStream;
            n += got;
            if (n == buf.len) return error.RequestTooLarge;
        }

        const tag = "Sec-WebSocket-Key:";
        const at = std.mem.indexOf(u8, buf[0..n], tag) orelse return error.NoWebSocketKey;
        const rest = buf[at + tag.len .. n];
        const key = std.mem.trim(u8, rest[0 .. std.mem.indexOf(u8, rest, "\r\n") orelse rest.len], " ");

        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(key);
        sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        sha.final(&digest);
        var accept_key: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

        var resp: [256]u8 = undefined;
        try writeAll(fd, try std.fmt.bufPrint(&resp,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{&accept_key}));
        return true;
    }
};

/// An unmasked binary frame, the way a server sends one.
fn writeFrame(fd: posix.socket_t, payload: []const u8) !void {
    var head: [4]u8 = undefined;
    head[0] = 0x82;
    var head_len: usize = 2;
    if (payload.len < 126) {
        head[1] = @intCast(payload.len);
    } else {
        head[1] = 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        head_len = 4;
    }
    try writeAll(fd, head[0..head_len]);
    try writeAll(fd, payload);
}

pub fn writeAll(fd: posix.socket_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

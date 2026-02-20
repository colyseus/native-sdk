const std = @import("std");
const Allocator = std.mem.Allocator;

// Use c_allocator (wraps malloc/free) for iOS compatibility
// GeneralPurposeAllocator uses mmap which has issues on iOS when used globally
const allocator = std.heap.c_allocator;

pub const colyseus_url_parts_t = extern struct {
    scheme: [*c]u8,
    host: [*c]u8,
    port: ?*u16,
    path_and_args: [*c]u8,
    url: [*c]u8,
};

fn cStrToSlice(cstr: [*c]const u8) ?[]const u8 {
    if (cstr == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
}

fn sliceToCStr(alloc: Allocator, slice: []const u8) ![*c]u8 {
    const buf = try alloc.alloc(u8, slice.len + 1);
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return buf.ptr;
}

fn freeString(alloc: Allocator, ptr: [*c]u8) void {
    if (ptr == null) return;
    const slice = cStrToSlice(ptr) orelse return;
    alloc.free(slice.ptr[0 .. slice.len + 1]);
}

fn getComponentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |pe| pe,
    };
}

export fn colyseus_parse_url(url_cstr: [*c]const u8) ?*colyseus_url_parts_t {
    return parseUrlImpl(url_cstr) catch null;
}

fn parseUrlImpl(url_cstr: [*c]const u8) !*colyseus_url_parts_t {
    const url_slice = cStrToSlice(url_cstr) orelse return error.InvalidUrl;

    var is_websocket = false;
    var is_secure = false;
    var parse_url: []const u8 = url_slice;
    var temp_buf: ?[]u8 = null;

    if (std.mem.startsWith(u8, url_slice, "wss://")) {
        is_websocket = true;
        is_secure = true;
        temp_buf = try allocator.alloc(u8, url_slice.len + 2);
        @memcpy(temp_buf.?[0..8], "https://");
        @memcpy(temp_buf.?[8..], url_slice[6..]);
        parse_url = temp_buf.?;
    } else if (std.mem.startsWith(u8, url_slice, "ws://")) {
        is_websocket = true;
        is_secure = false;
        temp_buf = try allocator.alloc(u8, url_slice.len + 2);
        @memcpy(temp_buf.?[0..7], "http://");
        @memcpy(temp_buf.?[7..], url_slice[5..]);
        parse_url = temp_buf.?;
    }

    defer {
        if (temp_buf) |buf| {
            allocator.free(buf);
        }
    }

    const uri = std.Uri.parse(parse_url) catch return error.ParseError;

    const parts = try allocator.create(colyseus_url_parts_t);
    errdefer allocator.destroy(parts);

    if (is_websocket) {
        parts.scheme = try sliceToCStr(allocator, if (is_secure) "wss" else "ws");
    } else {
        const scheme_slice = if (uri.scheme.len > 0) uri.scheme else "http";
        parts.scheme = try sliceToCStr(allocator, scheme_slice);
    }

    const host_component = uri.host orelse return error.NoHost;
    const host_slice = getComponentSlice(host_component);
    parts.host = try sliceToCStr(allocator, host_slice);

    if (uri.port) |p| {
        const port_ptr = try allocator.create(u16);
        port_ptr.* = p;
        parts.port = port_ptr;
    } else {
        parts.port = null;
    }

    var path_builder: std.ArrayListUnmanaged(u8) = .empty;
    defer path_builder.deinit(allocator);

    const path_slice = getComponentSlice(uri.path);
    if (path_slice.len > 0) {
        if (path_slice[0] == '/') {
            try path_builder.appendSlice(allocator, path_slice[1..]);
        } else {
            try path_builder.appendSlice(allocator, path_slice);
        }
    }

    if (uri.query) |query| {
        const query_slice = getComponentSlice(query);
        try path_builder.append(allocator, '?');
        try path_builder.appendSlice(allocator, query_slice);
    }

    parts.path_and_args = try sliceToCStr(allocator, path_builder.items);
    parts.url = try sliceToCStr(allocator, url_slice);

    return parts;
}

export fn colyseus_url_parts_free(parts: ?*colyseus_url_parts_t) void {
    if (parts == null) return;
    const p = parts.?;

    freeString(allocator, p.scheme);
    freeString(allocator, p.host);
    if (p.port) |port_ptr| {
        allocator.destroy(port_ptr);
    }
    freeString(allocator, p.path_and_args);
    freeString(allocator, p.url);
    allocator.destroy(p);
}

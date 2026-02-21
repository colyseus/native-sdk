const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

// Forward declarations for C types (avoiding @cImport to support iOS cross-compilation)
// These match the definitions in colyseus/settings.h and uthash.h

// Opaque UT_hash_handle - we only need to access the 'next' pointer for iteration
const UT_hash_handle = extern struct {
    tbl: ?*anyopaque,
    prev: ?*anyopaque,
    next: ?*anyopaque,
    hh_prev: ?*anyopaque,
    hh_next: ?*anyopaque,
    key: ?*anyopaque,
    keylen: c_uint,
    hashv: c_uint,
};

const colyseus_header_t = extern struct {
    key: [*c]u8,
    value: [*c]u8,
    hh: UT_hash_handle,
};

const colyseus_settings_t = extern struct {
    server_address: [*c]u8,
    server_port: [*c]u8,
    use_secure_protocol: bool,
    headers: ?*colyseus_header_t,
};

// External C function declarations
extern fn colyseus_settings_get_webrequest_endpoint(settings: *const colyseus_settings_t) [*c]u8;

// Direct C free declaration - bypasses Zig's libc requirement check
// For Android/iOS, libc is available at runtime but Zig can't provide it at build time
extern fn free(ptr: ?*anyopaque) void;

// Select allocator based on target platform
// - Android/iOS: use page_allocator (no libc dependency, Zig can't provide libc for these)
// - Other platforms: use c_allocator (more efficient for small allocations)
const builtin = @import("builtin");
const is_android = builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi);
const is_ios = builtin.os.tag == .ios;
const allocator = if (is_android or is_ios) std.heap.page_allocator else std.heap.c_allocator;

pub const colyseus_http_response_t = extern struct {
    status_code: c_int,
    body: [*c]u8,
    success: bool,
};

pub const colyseus_http_error_t = extern struct {
    code: c_int,
    message: [*c]u8,
};

pub const colyseus_http_t = extern struct {
    settings: *const colyseus_settings_t,
    auth_token: [*c]u8,
};

pub const colyseus_http_success_callback_t = ?*const fn (*const colyseus_http_response_t, ?*anyopaque) callconv(.c) void;
pub const colyseus_http_error_callback_t = ?*const fn (*const colyseus_http_error_t, ?*anyopaque) callconv(.c) void;

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

fn dupeString(alloc: Allocator, cstr: [*c]const u8) ![*c]u8 {
    if (cstr == null) return null;
    const slice = cStrToSlice(cstr) orelse return null;
    return sliceToCStr(alloc, slice);
}

fn freeString(alloc: Allocator, ptr: [*c]u8) void {
    if (ptr == null) return;
    const slice = cStrToSlice(ptr) orelse return;
    alloc.free(slice.ptr[0 .. slice.len + 1]);
}

export fn colyseus_http_create(settings: *const colyseus_settings_t) ?*colyseus_http_t {
    const http_client = allocator.create(colyseus_http_t) catch return null;
    http_client.* = .{
        .settings = settings,
        .auth_token = null,
    };
    return http_client;
}

export fn colyseus_http_free(http_client: ?*colyseus_http_t) void {
    if (http_client == null) return;
    const h = http_client.?;
    freeString(allocator, h.auth_token);
    allocator.destroy(h);
}

export fn colyseus_http_set_auth_token(http_client: ?*colyseus_http_t, token: [*c]const u8) void {
    if (http_client == null) return;
    const h = http_client.?;
    freeString(allocator, h.auth_token);
    h.auth_token = dupeString(allocator, token) catch null;
}

export fn colyseus_http_get_auth_token(http_client: ?*const colyseus_http_t) [*c]const u8 {
    if (http_client == null) return null;
    return http_client.?.auth_token;
}

export fn colyseus_http_get(
    http_client: ?*colyseus_http_t,
    path: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequest(http_client, .GET, path, null, on_success, on_error, userdata);
}

export fn colyseus_http_post(
    http_client: ?*colyseus_http_t,
    path: [*c]const u8,
    json_body: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequest(http_client, .POST, path, json_body, on_success, on_error, userdata);
}

export fn colyseus_http_put(
    http_client: ?*colyseus_http_t,
    path: [*c]const u8,
    json_body: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequest(http_client, .PUT, path, json_body, on_success, on_error, userdata);
}

export fn colyseus_http_delete(
    http_client: ?*colyseus_http_t,
    path: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequest(http_client, .DELETE, path, null, on_success, on_error, userdata);
}

export fn colyseus_http_response_free(response: ?*colyseus_http_response_t) void {
    if (response == null) return;
    freeString(allocator, response.?.body);
    response.?.body = null;
}

export fn colyseus_http_error_free(err: ?*colyseus_http_error_t) void {
    if (err == null) return;
    freeString(allocator, err.?.message);
    err.?.message = null;
}

fn httpRequest(
    http_client: ?*colyseus_http_t,
    method: http.Method,
    path_cstr: [*c]const u8,
    body_cstr: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequestImpl(http_client, method, path_cstr, body_cstr, on_success, on_error, userdata) catch |err| {
        if (on_error) |callback| {
            const msg = sliceToCStr(allocator, @errorName(err)) catch return;
            var error_response = colyseus_http_error_t{
                .code = 0,
                .message = msg,
            };
            callback(&error_response, userdata);
            freeString(allocator, msg);
        }
    };
}

fn httpRequestImpl(
    http_client: ?*colyseus_http_t,
    method: http.Method,
    path_cstr: [*c]const u8,
    body_cstr: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) !void {
    if (http_client == null) return error.NullHttpHandle;

    const h = http_client.?;
    const path_slice = cStrToSlice(path_cstr) orelse return error.InvalidPath;

    const base_url = colyseus_settings_get_webrequest_endpoint(h.settings);
    if (base_url == null) return error.NoBaseUrl;
    defer free(base_url);

    const base_slice = cStrToSlice(base_url) orelse return error.InvalidBaseUrl;

    const url = try buildUrl(allocator, base_slice, path_slice);
    defer allocator.free(url);

    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const extra_headers = try buildHeaders(h);
    defer allocator.free(extra_headers);

    const body_slice = if (body_cstr != null) cStrToSlice(body_cstr) else null;

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body_slice,
        .extra_headers = extra_headers,
        .response_writer = &response_writer.writer,
    }) catch |err| {
        if (on_error) |callback| {
            const msg = sliceToCStr(allocator, @errorName(err)) catch return err;
            var error_response = colyseus_http_error_t{
                .code = 0,
                .message = msg,
            };
            callback(&error_response, userdata);
            freeString(allocator, msg);
        }
        return err;
    };

    const status_code: c_int = @intFromEnum(result.status);
    const response_body = response_writer.written();
    const body_cstr_result = try sliceToCStr(allocator, response_body);

    if (status_code >= 400) {
        if (on_error) |callback| {
            var error_response = colyseus_http_error_t{
                .code = status_code,
                .message = body_cstr_result,
            };
            callback(&error_response, userdata);
            freeString(allocator, body_cstr_result);
        }
        return;
    }

    if (on_success) |callback| {
        var response = colyseus_http_response_t{
            .status_code = status_code,
            .body = body_cstr_result,
            .success = true,
        };
        callback(&response, userdata);
        freeString(allocator, body_cstr_result);
    }
}

fn buildUrl(alloc: Allocator, base: []const u8, path: []const u8) ![]u8 {
    const base_has_slash = base.len > 0 and base[base.len - 1] == '/';
    const path_has_slash = path.len > 0 and path[0] == '/';

    if (base_has_slash and path_has_slash) {
        const result = try alloc.alloc(u8, base.len + path.len - 1);
        @memcpy(result[0..base.len], base);
        @memcpy(result[base.len..], path[1..]);
        return result;
    } else if (!base_has_slash and !path_has_slash) {
        const result = try alloc.alloc(u8, base.len + 1 + path.len);
        @memcpy(result[0..base.len], base);
        result[base.len] = '/';
        @memcpy(result[base.len + 1 ..], path);
        return result;
    } else {
        const result = try alloc.alloc(u8, base.len + path.len);
        @memcpy(result[0..base.len], base);
        @memcpy(result[base.len..], path);
        return result;
    }
}

fn buildHeaders(http_client: *colyseus_http_t) ![]const http.Header {
    var headers: std.ArrayListUnmanaged(http.Header) = .empty;

    var header: ?*colyseus_header_t = http_client.settings.headers;
    while (header) |h| {
        const key = cStrToSlice(h.key);
        const value = cStrToSlice(h.value);
        if (key != null and value != null) {
            try headers.append(allocator, .{ .name = key.?, .value = value.? });
        }
        header = @ptrCast(@alignCast(h.hh.next));
    }

    if (http_client.auth_token != null) {
        const token_slice = cStrToSlice(http_client.auth_token);
        if (token_slice) |tok| {
            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{tok});
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        }
    }

    return headers.toOwnedSlice(allocator);
}

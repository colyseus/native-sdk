const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const is_emscripten = builtin.os.tag == .emscripten;

// std.http is not available on emscripten - HTTP should use JavaScript fetch API
const http = if (!is_emscripten) std.http else struct {
    pub const Method = enum { GET, POST, PUT, DELETE, PATCH };
    pub const Header = struct { name: []const u8, value: []const u8 };
    pub const Client = struct {
        allocator: Allocator,
        pub fn deinit(_: *@This()) void {}
        pub fn fetch(_: *@This(), _: anytype) !struct { status: enum { ok } } {
            return error.NotSupportedOnWeb;
        }
    };
};

const OwnedHeaders = struct {
    headers: []const http.Header,
    auth_value: ?[]u8, // only field allocated by Zig

    fn deinit(self: *OwnedHeaders, alloc: Allocator) void {
        if (self.auth_value) |v| alloc.free(v);
        alloc.free(self.headers);
    }
};

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

// Field layout must match colyseus_settings_t in include/colyseus/settings.h.
const colyseus_settings_t = extern struct {
    server_address: [*c]u8,
    server_port: [*c]u8,
    use_secure_protocol: bool,
    tls_skip_verification: bool,
    headers: ?*colyseus_header_t,
    ca_pem_data: [*c]const u8,
    ca_pem_len: usize,
};

// External C function declarations
extern fn colyseus_settings_get_webrequest_endpoint(settings: *const colyseus_settings_t) [*c]u8;

// Bundled Mozilla CA roots (src/certs/ca_bundle.c). These are C array symbols, so
// the symbol address is the data itself — take &symbol rather than reading it as a
// value. Used to give HTTPS matchmaking the same device-independent trust baseline
// as the WSS transport (see ws_tls_init), instead of relying solely on the OS store.
extern const colyseus_ca_bundle_pem: u8;
extern const colyseus_ca_bundle_pem_len: usize;

// Direct C free declaration - bypasses Zig's libc requirement check
// For Android/iOS, libc is available at runtime but Zig can't provide it at build time
extern fn free(ptr: ?*anyopaque) void;

// Select allocator based on target platform
// - Android/iOS/Emscripten: use page_allocator (no libc dependency)
// - Other platforms: use c_allocator (more efficient for small allocations)
const is_android = builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi);
const is_ios = builtin.os.tag == .ios;
const allocator = if (is_android or is_ios or is_emscripten) std.heap.page_allocator else std.heap.c_allocator;

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

export fn colyseus_http_patch(
    http_client: ?*colyseus_http_t,
    path: [*c]const u8,
    json_body: [*c]const u8,
    on_success: colyseus_http_success_callback_t,
    on_error: colyseus_http_error_callback_t,
    userdata: ?*anyopaque,
) void {
    httpRequest(http_client, .PATCH, path, json_body, on_success, on_error, userdata);
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

// base64 decoder that skips PEM line breaks/whitespace, matching std's Bundle parser.
const pem_base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

// Append every certificate in a PEM blob to an existing Certificate.Bundle. Mirrors
// the marker-scanning loop in std.crypto.Certificate.Bundle.addCertsFromFile, but
// reads from an in-memory slice (our CA roots are compiled-in / passed via settings,
// not files). parseCert skips expired/duplicate/unrecognized certs internally.
fn addCertsFromPem(cb: *std.crypto.Certificate.Bundle, gpa: Allocator, pem: []const u8) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const now_sec = std.time.timestamp();

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin_start| {
        const cert_start = begin_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;

        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        // base64 decodes to at most encoded.len bytes — a safe upper bound to reserve.
        try cb.bytes.ensureUnusedCapacity(gpa, encoded.len);
        const decoded_start: u32 = @intCast(cb.bytes.items.len);
        const dest = cb.bytes.allocatedSlice()[decoded_start..];
        cb.bytes.items.len += try pem_base64.decode(dest, encoded);
        try cb.parseCert(gpa, decoded_start, now_sec);
    }
}

// Populate the std.http.Client trust store to mirror the WSS transport: OS system
// store (best-effort) + bundled Mozilla roots + any settings-provided override.
// Without this, std.http only trusts the OS store, which is unreliable on Android
// and can't honor certificate_bundle_override — so matchmaking HTTPS would fail
// where the WSS connection (post-#24) succeeds.
fn setupCaBundle(client: *http.Client, settings: *const colyseus_settings_t) void {
    // System store first (rescan clears the bundle, so it must run before we add).
    // Best-effort: on Android/missing-store this fails and we fall back to bundled.
    client.ca_bundle.rescan(allocator) catch {};

    const bundled_ptr: [*]const u8 = @ptrCast(&colyseus_ca_bundle_pem);
    // Length includes the trailing NUL; drop it so the PEM scanner sees clean text.
    const bundled_len = if (colyseus_ca_bundle_pem_len > 0) colyseus_ca_bundle_pem_len - 1 else 0;
    addCertsFromPem(&client.ca_bundle, allocator, bundled_ptr[0..bundled_len]) catch |err|
        std.log.warn("Failed to add bundled CA roots for HTTPS: {}", .{err});

    if (settings.ca_pem_data != null and settings.ca_pem_len > 0) {
        const override_len = if (settings.ca_pem_len > 0) settings.ca_pem_len - 1 else 0;
        const override_pem = settings.ca_pem_data[0..override_len];
        addCertsFromPem(&client.ca_bundle, allocator, override_pem) catch |err|
            std.log.warn("Failed to add override CA for HTTPS: {}", .{err});
    }

    // We populated the bundle ourselves; stop fetch() from rescanning (which clears it).
    client.next_https_rescan_certs = false;
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

    // Give HTTPS matchmaking the same trust roots as the WSS transport.
    // Plain http:// never touches the CA bundle, so skip the setup cost there.
    if (comptime !is_emscripten) {
        if (h.settings.use_secure_protocol) setupCaBundle(&client, h.settings);
    }

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const body_slice = if (body_cstr != null) cStrToSlice(body_cstr) else null;

    var owned_headers = try buildHeaders(h, body_slice != null);
    defer owned_headers.deinit(allocator);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body_slice,
        .extra_headers = owned_headers.headers,
        .response_writer = &response_writer.writer,
    });

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

fn buildHeaders(http_client: *colyseus_http_t, has_body: bool) !OwnedHeaders {
    var headers: std.ArrayListUnmanaged(http.Header) = .empty;
    errdefer headers.deinit(allocator); // leak-safe on any failure

    var auth_value: ?[]u8 = null;
    errdefer if (auth_value) |v| allocator.free(v); // leak-safe on any failure

    // All Colyseus API communication uses JSON
    if (has_body) {
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    }
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });

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
            auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{tok});
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value.? });
        }
    }

    return OwnedHeaders{
        .headers = try headers.toOwnedSlice(allocator),
        .auth_value = auth_value,
    };
}

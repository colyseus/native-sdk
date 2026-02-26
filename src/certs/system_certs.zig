const std = @import("std");
const builtin = @import("builtin");
const Certificate = std.crypto.Certificate;
const Allocator = std.mem.Allocator;

// Platform-specific allocator selection
const is_android = builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi);
const is_ios = builtin.os.tag == .ios;
const is_emscripten = builtin.os.tag == .emscripten;
const allocator = if (is_android or is_ios or is_emscripten) std.heap.page_allocator else std.heap.c_allocator;

// Global certificate bundle
var g_bundle: ?Certificate.Bundle = null;
var g_init_attempted: bool = false;
var g_init_success: bool = false;

// PEM output buffer for mbedTLS compatibility
var g_pem_buffer: ?[]u8 = null;

/// Initialize system certificates by scanning OS certificate stores.
/// Returns true if certificates were loaded successfully.
/// This is safe to call multiple times - subsequent calls are no-ops.
pub export fn colyseus_system_certs_init() bool {
    if (g_init_attempted) {
        return g_init_success;
    }
    g_init_attempted = true;

    // Emscripten doesn't have system certificates
    if (is_emscripten) {
        return false;
    }

    g_bundle = Certificate.Bundle{};

    g_bundle.?.rescan(allocator) catch |err| {
        std.log.warn("Failed to load system certificates: {}", .{err});
        g_bundle.?.deinit(allocator);
        g_bundle = null;
        return false;
    };

    // Check if any certificates were loaded
    if (g_bundle.?.bytes.items.len == 0) {
        std.log.warn("No system certificates found", .{});
        g_bundle.?.deinit(allocator);
        g_bundle = null;
        return false;
    }

    // Convert DER certificates to PEM format for mbedTLS
    if (!convertToPem()) {
        g_bundle.?.deinit(allocator);
        g_bundle = null;
        return false;
    }

    g_init_success = true;
    std.log.info("Loaded system certificates ({d} bytes)", .{g_pem_buffer.?.len});
    return true;
}

/// Get the loaded certificates in PEM format.
/// Returns null if no certificates are loaded.
pub export fn colyseus_system_certs_get_pem() ?[*]const u8 {
    if (g_pem_buffer) |buf| {
        return buf.ptr;
    }
    return null;
}

/// Get the length of the PEM certificate data (including null terminator).
/// Returns 0 if no certificates are loaded.
pub export fn colyseus_system_certs_get_pem_len() usize {
    if (g_pem_buffer) |buf| {
        return buf.len;
    }
    return 0;
}

/// Check if system certificates are available.
pub export fn colyseus_system_certs_available() bool {
    return g_init_success and g_pem_buffer != null;
}

/// Clean up and free certificate resources.
pub export fn colyseus_system_certs_cleanup() void {
    if (g_pem_buffer) |buf| {
        allocator.free(buf);
        g_pem_buffer = null;
    }
    if (g_bundle) |*bundle| {
        bundle.deinit(allocator);
        g_bundle = null;
    }
    g_init_attempted = false;
    g_init_success = false;
}

/// Convert DER certificates to PEM format for mbedTLS.
/// mbedTLS expects PEM format with BEGIN/END markers and base64 encoding.
fn convertToPem() bool {
    const bundle = g_bundle orelse return false;

    // Estimate PEM size: each DER cert becomes ~4/3 larger when base64 encoded,
    // plus headers/footers (~60 bytes per cert)
    const cert_count = bundle.map.count();
    if (cert_count == 0) return false;

    const der_size = bundle.bytes.items.len;
    const estimated_pem_size = (der_size * 4 / 3) + (cert_count * 100) + 1; // +1 for null terminator

    var pem_buffer = allocator.alloc(u8, estimated_pem_size) catch return false;
    var pem_len: usize = 0;

    const begin_marker = "-----BEGIN CERTIFICATE-----\n";
    const end_marker = "-----END CERTIFICATE-----\n";

    // Iterate through all certificates in the map
    var iter = bundle.map.iterator();
    while (iter.next()) |entry| {
        const cert_start = entry.value_ptr.*;

        // Find the certificate end by parsing the DER structure
        const cert_bytes = bundle.bytes.items[cert_start..];
        const cert_len = getDerCertLength(cert_bytes) orelse continue;

        const der_cert = bundle.bytes.items[cert_start .. cert_start + cert_len];

        // Write BEGIN marker
        if (pem_len + begin_marker.len > pem_buffer.len) break;
        @memcpy(pem_buffer[pem_len .. pem_len + begin_marker.len], begin_marker);
        pem_len += begin_marker.len;

        // Base64 encode the DER certificate with line breaks
        const base64_len = std.base64.standard.Encoder.calcSize(der_cert.len);
        if (pem_len + base64_len + end_marker.len + 1 > pem_buffer.len) break;

        const encoded = std.base64.standard.Encoder.encode(pem_buffer[pem_len..], der_cert);
        pem_len += encoded.len;

        // Add newline after base64
        pem_buffer[pem_len] = '\n';
        pem_len += 1;

        // Write END marker
        @memcpy(pem_buffer[pem_len .. pem_len + end_marker.len], end_marker);
        pem_len += end_marker.len;
    }

    // Null terminate for mbedTLS
    pem_buffer[pem_len] = 0;
    pem_len += 1;

    // Store the buffer (trimmed to actual size)
    g_pem_buffer = pem_buffer[0..pem_len];

    return pem_len > 1; // More than just null terminator
}

/// Parse DER structure to get certificate length.
/// DER certificates start with a SEQUENCE tag (0x30) followed by length.
fn getDerCertLength(der: []const u8) ?usize {
    if (der.len < 2) return null;

    // Check for SEQUENCE tag
    if (der[0] != 0x30) return null;

    // Parse length
    const len_byte = der[1];
    if (len_byte < 0x80) {
        // Short form: length is directly in this byte
        return 2 + len_byte;
    } else if (len_byte == 0x80) {
        // Indefinite length - not valid for DER
        return null;
    } else {
        // Long form: len_byte & 0x7F = number of length bytes
        const num_len_bytes = len_byte & 0x7F;
        if (num_len_bytes > 4 or der.len < 2 + num_len_bytes) return null;

        var length: usize = 0;
        for (der[2 .. 2 + num_len_bytes]) |b| {
            length = (length << 8) | b;
        }

        return 2 + num_len_bytes + length;
    }
}

const std = @import("std");
const msgpack = @import("msgpack");

/// Result type for decoding operations
pub const DecodeResult = extern struct {
    success: bool,
    error_message: [*:0]const u8,
};

/// Decoded value type enumeration (matches Godot Variant types)
pub const ValueType = enum(c_int) {
    nil = 0,
    bool = 1,
    int = 2,
    float = 3,
    string = 4,
    array = 5,
    dictionary = 6,
    binary = 7,
};

/// Callback type for receiving decoded values
/// The C code will implement this to convert values to Godot Variants
pub const ValueCallback = *const fn (
    value_type: ValueType,
    // For simple types: the value data
    int_value: i64,
    float_value: f64,
    bool_value: bool,
    // For string/binary: pointer and length
    data_ptr: ?[*]const u8,
    data_len: usize,
    // For containers: element count (array length or map pair count)
    container_len: usize,
    // User data
    userdata: ?*anyopaque,
) callconv(.c) void;

/// Callback for starting/ending containers
pub const ContainerCallback = *const fn (
    is_start: bool,
    is_array: bool, // true = array, false = map/dictionary
    length: usize,
    userdata: ?*anyopaque,
) callconv(.c) void;

/// Decoder context passed from C
pub const DecoderContext = extern struct {
    value_callback: ValueCallback,
    container_callback: ContainerCallback,
    userdata: ?*anyopaque,
};

/// Global allocator for msgpack decoding
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// Decode a msgpack payload and call the appropriate callbacks
/// Returns true on success, false on error
export fn msgpack_decode_to_godot(
    data: [*]const u8,
    len: usize,
    ctx: *const DecoderContext,
) callconv(.c) bool {
    const allocator = gpa.allocator();

    // Handle empty data
    if (len == 0) {
        ctx.value_callback(.nil, 0, 0, false, null, 0, 0, ctx.userdata);
        return true;
    }

    // Create a fixed reader from the input data slice
    const data_slice = data[0..len];
    var reader = std.Io.Reader.fixed(data_slice);

    // Create a dummy writer (we only need reading)
    var write_buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buffer);

    var packer = msgpack.PackerIO.init(&reader, &writer);

    // Try to decode
    const payload = packer.read(allocator) catch {
        return false;
    };
    defer payload.free(allocator);

    // Convert payload to Godot types via callbacks
    return decodePayload(payload, ctx, allocator);
}

/// Recursively decode a payload and emit callbacks
fn decodePayload(payload: msgpack.Payload, ctx: *const DecoderContext, allocator: std.mem.Allocator) bool {
    switch (payload) {
        .nil => {
            ctx.value_callback(
                .nil,
                0,
                0,
                false,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
        .bool => |v| {
            ctx.value_callback(
                .bool,
                0,
                0,
                v,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
        .int => |v| {
            ctx.value_callback(
                .int,
                v,
                0,
                false,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
        .uint => |v| {
            // Convert uint to int (may overflow for very large values)
            const int_val: i64 = if (v <= std.math.maxInt(i64))
                @intCast(v)
            else
                std.math.maxInt(i64);
            ctx.value_callback(
                .int,
                int_val,
                0,
                false,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
        .float => |v| {
            ctx.value_callback(
                .float,
                0,
                v,
                false,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
        .str => |s| {
            const str_value = s.value();
            ctx.value_callback(
                .string,
                0,
                0,
                false,
                str_value.ptr,
                str_value.len,
                0,
                ctx.userdata,
            );
            return true;
        },
        .bin => |b| {
            const bin_value = b.value();
            ctx.value_callback(
                .binary,
                0,
                0,
                false,
                bin_value.ptr,
                bin_value.len,
                0,
                ctx.userdata,
            );
            return true;
        },
        .arr => |arr| {
            // Signal start of array
            ctx.container_callback(true, true, arr.len, ctx.userdata);

            // Decode each element
            for (arr) |elem| {
                if (!decodePayload(elem, ctx, allocator)) {
                    return false;
                }
            }

            // Signal end of array
            ctx.container_callback(false, true, arr.len, ctx.userdata);
            return true;
        },
        .map => |m| {
            const count = m.count();

            // Signal start of dictionary
            ctx.container_callback(true, false, count, ctx.userdata);

            // Decode each key-value pair
            var it = m.map.iterator();
            while (it.next()) |entry| {
                // Decode key
                if (!decodePayload(entry.key_ptr.*, ctx, allocator)) {
                    return false;
                }
                // Decode value
                if (!decodePayload(entry.value_ptr.*, ctx, allocator)) {
                    return false;
                }
            }

            // Signal end of dictionary
            ctx.container_callback(false, false, count, ctx.userdata);
            return true;
        },
        .ext => |e| {
            // Extension types - treat as binary with type info
            ctx.value_callback(
                .binary,
                @as(i64, e.type),
                0,
                false,
                e.data.ptr,
                e.data.len,
                0,
                ctx.userdata,
            );
            return true;
        },
        .timestamp => |ts| {
            // Timestamps - convert to float (seconds since epoch)
            const seconds: f64 = @floatFromInt(ts.seconds);
            const nanos: f64 = @floatFromInt(ts.nanoseconds);
            const total = seconds + nanos / 1_000_000_000.0;
            ctx.value_callback(
                .float,
                0,
                total,
                false,
                null,
                0,
                0,
                ctx.userdata,
            );
            return true;
        },
    }
}

/// Get error message for the last decode operation
export fn msgpack_get_last_error() callconv(.c) [*:0]const u8 {
    return "Unknown error";
}

/// Free any resources allocated during decoding
export fn msgpack_cleanup() callconv(.c) void {
    // Currently using arena-style deallocation via payload.free()
    // Nothing to clean up globally
}

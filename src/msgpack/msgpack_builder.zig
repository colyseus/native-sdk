const std = @import("std");
const msgpack = @import("msgpack");

const Payload = msgpack.Payload;
const Allocator = std.mem.Allocator;

// Select allocator based on target platform
// - Use c_allocator for platforms that provide libc (including emscripten)
// - page_allocator can fail on some WASM environments
const builtin = @import("builtin");
const is_android = builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi);
const is_ios = builtin.os.tag == .ios;
const allocator = if (is_android or is_ios) std.heap.page_allocator else std.heap.c_allocator;

const PayloadType = enum {
    map,
    array,
    primitive,
};

const PayloadWrapper = struct {
    payload_type: PayloadType,
    payload: ?Payload = null,
    array_elements: ?std.ArrayList(Payload) = null,

    fn deinit(self: *PayloadWrapper) void {
        if (self.array_elements) |*list| {
            for (list.items) |*item| {
                item.free(allocator);
            }
            list.deinit(allocator);
        }
        if (self.payload) |*p| {
            p.free(allocator);
        }
    }
};

fn createMapWrapper() ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .map,
        .payload = Payload.mapPayload(allocator),
        .array_elements = null,
    };
    return wrapper;
}

fn createArrayWrapper() ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .array,
        .payload = null,
        .array_elements = .{},
    };
    return wrapper;
}

fn createPrimitiveWrapper(payload: Payload) ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .primitive,
        .payload = payload,
        .array_elements = null,
    };
    return wrapper;
}

// ============================================================================
// Creation functions
// ============================================================================

export fn colyseus_message_map_create() ?*PayloadWrapper {
    return createMapWrapper();
}

export fn colyseus_message_array_create() ?*PayloadWrapper {
    return createArrayWrapper();
}

export fn colyseus_message_nil_create() ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.nilToPayload());
}

export fn colyseus_message_bool_create(value: bool) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.boolToPayload(value));
}

export fn colyseus_message_int_create(value: i64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.intToPayload(value));
}

export fn colyseus_message_uint_create(value: u64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.uintToPayload(value));
}

export fn colyseus_message_float_create(value: f64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.floatToPayload(value));
}

export fn colyseus_message_str_create(value: [*c]const u8) ?*PayloadWrapper {
    if (value == null) return createPrimitiveWrapper(Payload.nilToPayload());
    const str = std.mem.span(value);
    const payload = Payload.strToPayload(str, allocator) catch return null;
    return createPrimitiveWrapper(payload);
}

// ============================================================================
// Map operations
// ============================================================================

export fn colyseus_message_map_put_str(map: ?*PayloadWrapper, key: [*c]const u8, value: [*c]const u8) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    if (value == null) {
        map.?.payload.?.mapPut(key_str, Payload.nilToPayload()) catch return;
    } else {
        const value_str = std.mem.span(value);
        const str_payload = Payload.strToPayload(value_str, allocator) catch return;
        map.?.payload.?.mapPut(key_str, str_payload) catch return;
    }
}

export fn colyseus_message_map_put_int(map: ?*PayloadWrapper, key: [*c]const u8, value: i64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.intToPayload(value)) catch return;
}

export fn colyseus_message_map_put_uint(map: ?*PayloadWrapper, key: [*c]const u8, value: u64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.uintToPayload(value)) catch return;
}

export fn colyseus_message_map_put_float(map: ?*PayloadWrapper, key: [*c]const u8, value: f64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.floatToPayload(value)) catch return;
}

export fn colyseus_message_map_put_bool(map: ?*PayloadWrapper, key: [*c]const u8, value: bool) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.boolToPayload(value)) catch return;
}

export fn colyseus_message_map_put_nil(map: ?*PayloadWrapper, key: [*c]const u8) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.nilToPayload()) catch return;
}

export fn colyseus_message_map_put_msg(map: ?*PayloadWrapper, key: [*c]const u8, value: ?*PayloadWrapper) void {
    if (map == null or key == null or value == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);

    const val_payload = takePayload(value.?) orelse return;
    map.?.payload.?.mapPut(key_str, val_payload) catch return;
}

// ============================================================================
// Array operations
// ============================================================================

export fn colyseus_message_array_push_str(arr: ?*PayloadWrapper, value: [*c]const u8) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    if (value == null) {
        list.append(allocator, Payload.nilToPayload()) catch return;
    } else {
        const value_str = std.mem.span(value);
        const str_payload = Payload.strToPayload(value_str, allocator) catch return;
        list.append(allocator, str_payload) catch return;
    }
}

export fn colyseus_message_array_push_int(arr: ?*PayloadWrapper, value: i64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.intToPayload(value)) catch return;
}

export fn colyseus_message_array_push_uint(arr: ?*PayloadWrapper, value: u64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.uintToPayload(value)) catch return;
}

export fn colyseus_message_array_push_float(arr: ?*PayloadWrapper, value: f64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.floatToPayload(value)) catch return;
}

export fn colyseus_message_array_push_bool(arr: ?*PayloadWrapper, value: bool) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.boolToPayload(value)) catch return;
}

export fn colyseus_message_array_push_nil(arr: ?*PayloadWrapper) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.nilToPayload()) catch return;
}

export fn colyseus_message_array_push_msg(arr: ?*PayloadWrapper, value: ?*PayloadWrapper) void {
    if (arr == null or value == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;

    const val_payload = takePayload(value.?) orelse return;
    list.append(allocator, val_payload) catch return;
}

// ============================================================================
// Payload ownership
//
// A wrapper's payload leaves it in one of two ways, and they are not the same:
//
//   takePayload()   nesting — the parent adopts the payload, so the child must
//                   never free it again. The child wrapper survives but empty,
//                   which makes a later colyseus_message_free() a no-op.
//   copyPayload()   encoding — the builder keeps everything it had, so the same
//                   message can be encoded (and sent) more than once.
//
// zig-msgpack's Pack.write does not consume what it writes, so the encode copy
// is ours to free once the bytes are out.
// ============================================================================

const CopyError = Payload.Error || error{ OutOfMemory, UnsupportedNonStringMapKey };

fn copyValue(p: Payload) CopyError!Payload {
    return switch (p) {
        .nil, .bool, .int, .uint, .float, .timestamp => p,
        .str => |s| try Payload.strToPayload(s.str, allocator),
        .bin => |b| try Payload.binToPayload(b.bin, allocator),
        .ext => |e| try Payload.extToPayload(e.type, e.data, allocator),
        .arr => |items| {
            var arr_payload = try Payload.arrPayload(items.len, allocator);
            errdefer arr_payload.free(allocator);
            for (items, 0..) |item, i| {
                try arr_payload.setArrElement(i, try copyValue(item));
            }
            return arr_payload;
        },
        .map => |m| {
            var new_payload = Payload.mapPayload(allocator);
            errdefer new_payload.free(allocator);
            var it = m.iterator();
            while (it.next()) |entry| {
                // Every key this builder can produce is a string.
                const key = switch (entry.key_ptr.*) {
                    .str => |ks| ks.str,
                    else => return error.UnsupportedNonStringMapKey,
                };
                try new_payload.mapPut(key, try copyValue(entry.value_ptr.*));
            }
            return new_payload;
        },
    };
}

/// Hand the payload to a new owner, leaving the wrapper empty.
fn takePayload(wrapper: *PayloadWrapper) ?Payload {
    switch (wrapper.payload_type) {
        .map, .primitive => {
            const p = wrapper.payload orelse return null;
            wrapper.payload = null;
            return p;
        },
        .array => {
            const list = if (wrapper.array_elements) |*l| l else return null;
            var arr_payload = Payload.arrPayload(list.items.len, allocator) catch return null;
            for (list.items, 0..) |item, i| {
                arr_payload.setArrElement(i, item) catch {
                    arr_payload.free(allocator);
                    return null;
                };
            }
            // The elements moved into arr_payload; dropping them here is what
            // keeps the wrapper's deinit from freeing them a second time.
            list.clearRetainingCapacity();
            return arr_payload;
        },
    }
}

/// A throwaway copy for one encode pass. The wrapper keeps its own.
fn copyPayload(wrapper: *PayloadWrapper) ?Payload {
    switch (wrapper.payload_type) {
        .map, .primitive => {
            const p = wrapper.payload orelse return null;
            return copyValue(p) catch null;
        },
        .array => {
            const list = wrapper.array_elements orelse return null;
            var arr_payload = Payload.arrPayload(list.items.len, allocator) catch return null;
            errdefer arr_payload.free(allocator);
            for (list.items, 0..) |item, i| {
                const copied = copyValue(item) catch {
                    arr_payload.free(allocator);
                    return null;
                };
                arr_payload.setArrElement(i, copied) catch {
                    copied.free(allocator);
                    arr_payload.free(allocator);
                    return null;
                };
            }
            return arr_payload;
        },
    }
}

// ============================================================================
// Encoding
// ============================================================================

export fn colyseus_message_encode(wrapper: ?*PayloadWrapper, out_len: *usize) ?[*]u8 {
    if (wrapper == null) {
        out_len.* = 0;
        return null;
    }

    const payload_to_encode = copyPayload(wrapper.?) orelse {
        out_len.* = 0;
        return null;
    };
    defer payload_to_encode.free(allocator);

    // Create buffer for encoding
    var buffer: [16384]u8 = undefined;
    const compat = msgpack.compat;
    var stream = compat.fixedBufferStream(&buffer);

    const StreamType = @TypeOf(stream);
    var packer = msgpack.Pack(
        *StreamType,
        *StreamType,
        StreamType.WriteError,
        StreamType.ReadError,
        StreamType.write,
        StreamType.read,
    ).init(&stream, &stream);

    packer.write(payload_to_encode) catch {
        out_len.* = 0;
        return null;
    };

    const encoded_len = stream.pos;

    // Copy to persistent buffer
    const result = allocator.alloc(u8, encoded_len) catch {
        out_len.* = 0;
        return null;
    };
    @memcpy(result, buffer[0..encoded_len]);

    // Caller owns the returned buffer; free with colyseus_message_encoded_free.
    out_len.* = encoded_len;
    return result.ptr;
}

// ============================================================================
// Cleanup
// ============================================================================

export fn colyseus_message_free(wrapper: ?*PayloadWrapper) void {
    if (wrapper == null) return;
    wrapper.?.deinit();
    allocator.destroy(wrapper.?);
}

export fn colyseus_message_encoded_free(data: ?[*]u8, len: usize) void {
    if (data == null or len == 0) return;
    allocator.free(data.?[0..len]);
}

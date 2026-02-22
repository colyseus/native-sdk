const std = @import("std");
const msgpack = @import("msgpack");

const Payload = msgpack.Payload;
const Allocator = std.mem.Allocator;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const PayloadType = enum {
    map,
    array,
    primitive,
};

const PayloadWrapper = struct {
    payload_type: PayloadType,
    payload: ?Payload = null,
    array_elements: ?std.ArrayList(Payload) = null,
    encoded_data: ?[]u8 = null,

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
        if (self.encoded_data) |data| {
            allocator.free(data);
        }
    }
};

fn createMapWrapper() ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .map,
        .payload = Payload.mapPayload(allocator),
        .array_elements = null,
        .encoded_data = null,
    };
    return wrapper;
}

fn createArrayWrapper() ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .array,
        .payload = null,
        .array_elements = .{},
        .encoded_data = null,
    };
    return wrapper;
}

fn createPrimitiveWrapper(payload: Payload) ?*PayloadWrapper {
    const wrapper = allocator.create(PayloadWrapper) catch return null;
    wrapper.* = .{
        .payload_type = .primitive,
        .payload = payload,
        .array_elements = null,
        .encoded_data = null,
    };
    return wrapper;
}

// ============================================================================
// Creation functions
// ============================================================================

export fn msgpack_map_create() ?*PayloadWrapper {
    return createMapWrapper();
}

export fn msgpack_array_create() ?*PayloadWrapper {
    return createArrayWrapper();
}

export fn msgpack_nil_create() ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.nilToPayload());
}

export fn msgpack_bool_create(value: bool) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.boolToPayload(value));
}

export fn msgpack_int_create(value: i64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.intToPayload(value));
}

export fn msgpack_uint_create(value: u64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.uintToPayload(value));
}

export fn msgpack_float_create(value: f64) ?*PayloadWrapper {
    return createPrimitiveWrapper(Payload.floatToPayload(value));
}

export fn msgpack_str_create(value: [*c]const u8) ?*PayloadWrapper {
    if (value == null) return createPrimitiveWrapper(Payload.nilToPayload());
    const str = std.mem.span(value);
    const payload = Payload.strToPayload(str, allocator) catch return null;
    return createPrimitiveWrapper(payload);
}

// ============================================================================
// Map operations
// ============================================================================

export fn msgpack_map_put_str(map: ?*PayloadWrapper, key: [*c]const u8, value: [*c]const u8) void {
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

export fn msgpack_map_put_int(map: ?*PayloadWrapper, key: [*c]const u8, value: i64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.intToPayload(value)) catch return;
}

export fn msgpack_map_put_uint(map: ?*PayloadWrapper, key: [*c]const u8, value: u64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.uintToPayload(value)) catch return;
}

export fn msgpack_map_put_float(map: ?*PayloadWrapper, key: [*c]const u8, value: f64) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.floatToPayload(value)) catch return;
}

export fn msgpack_map_put_bool(map: ?*PayloadWrapper, key: [*c]const u8, value: bool) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.boolToPayload(value)) catch return;
}

export fn msgpack_map_put_nil(map: ?*PayloadWrapper, key: [*c]const u8) void {
    if (map == null or key == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);
    map.?.payload.?.mapPut(key_str, Payload.nilToPayload()) catch return;
}

export fn msgpack_map_put_payload(map: ?*PayloadWrapper, key: [*c]const u8, value: ?*PayloadWrapper) void {
    if (map == null or key == null or value == null or map.?.payload_type != .map) return;
    const key_str = std.mem.span(key);

    const val_payload = getPayloadForEncoding(value.?) orelse return;
    map.?.payload.?.mapPut(key_str, val_payload) catch return;
}

// ============================================================================
// Array operations
// ============================================================================

export fn msgpack_array_push_str(arr: ?*PayloadWrapper, value: [*c]const u8) void {
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

export fn msgpack_array_push_int(arr: ?*PayloadWrapper, value: i64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.intToPayload(value)) catch return;
}

export fn msgpack_array_push_uint(arr: ?*PayloadWrapper, value: u64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.uintToPayload(value)) catch return;
}

export fn msgpack_array_push_float(arr: ?*PayloadWrapper, value: f64) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.floatToPayload(value)) catch return;
}

export fn msgpack_array_push_bool(arr: ?*PayloadWrapper, value: bool) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.boolToPayload(value)) catch return;
}

export fn msgpack_array_push_nil(arr: ?*PayloadWrapper) void {
    if (arr == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;
    list.append(allocator, Payload.nilToPayload()) catch return;
}

export fn msgpack_array_push_payload(arr: ?*PayloadWrapper, value: ?*PayloadWrapper) void {
    if (arr == null or value == null or arr.?.payload_type != .array) return;
    var list = &arr.?.array_elements.?;

    const val_payload = getPayloadForEncoding(value.?) orelse return;
    list.append(allocator, val_payload) catch return;
}

// ============================================================================
// Helper to get Payload for encoding
// ============================================================================

fn getPayloadForEncoding(wrapper: *PayloadWrapper) ?Payload {
    switch (wrapper.payload_type) {
        .map, .primitive => return wrapper.payload,
        .array => {
            if (wrapper.array_elements) |list| {
                var arr_payload = Payload.arrPayload(list.items.len, allocator) catch return null;
                for (list.items, 0..) |item, i| {
                    arr_payload.setArrElement(i, item) catch return null;
                }
                return arr_payload;
            }
            return null;
        },
    }
}

// ============================================================================
// Encoding
// ============================================================================

export fn msgpack_payload_encode(wrapper: ?*PayloadWrapper, out_len: *usize) ?[*]u8 {
    if (wrapper == null) {
        out_len.* = 0;
        return null;
    }

    // Free previous encoded data if exists
    if (wrapper.?.encoded_data) |data| {
        allocator.free(data);
        wrapper.?.encoded_data = null;
    }

    // Get the payload to encode
    const payload_to_encode = getPayloadForEncoding(wrapper.?) orelse {
        out_len.* = 0;
        return null;
    };

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

    wrapper.?.encoded_data = result;
    out_len.* = encoded_len;
    return result.ptr;
}

// ============================================================================
// Cleanup
// ============================================================================

export fn msgpack_payload_free(wrapper: ?*PayloadWrapper) void {
    if (wrapper == null) return;
    wrapper.?.deinit();
    allocator.destroy(wrapper.?);
}

export fn msgpack_encoded_data_free(data: ?[*]u8, len: usize) void {
    if (data == null or len == 0) return;
    allocator.free(data.?[0..len]);
}

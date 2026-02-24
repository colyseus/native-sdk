const std = @import("std");
const builtin = @import("builtin");
const msgpack = @import("msgpack");

const Payload = msgpack.Payload;

const is_android = builtin.os.tag == .linux and (builtin.abi == .android or builtin.abi == .androideabi);
const is_ios = builtin.os.tag == .ios;
const is_emscripten = builtin.os.tag == .emscripten;
const allocator = if (is_android or is_ios or is_emscripten) std.heap.page_allocator else std.heap.c_allocator;

const ColyseusMessageType = enum(c_int) {
    nil = 0,
    bool = 1,
    int = 2,
    uint = 3,
    float = 4,
    str = 5,
    bin = 6,
    array = 7,
    map = 8,
};

const ReaderWrapper = struct {
    payload: Payload,
    owns_payload: bool,
    str_buffer: ?[]u8 = null,

    fn deinit(self: *ReaderWrapper) void {
        if (self.str_buffer) |buf| {
            allocator.free(buf);
        }
        if (self.owns_payload) {
            var p = self.payload;
            p.free(allocator);
        }
    }
};

fn createReader(payload: Payload, owns: bool) ?*ReaderWrapper {
    const wrapper = allocator.create(ReaderWrapper) catch return null;
    wrapper.* = .{
        .payload = payload,
        .owns_payload = owns,
        .str_buffer = null,
    };
    return wrapper;
}

fn getPayloadType(payload: Payload) ColyseusMessageType {
    return switch (payload) {
        .nil => .nil,
        .bool => .bool,
        .int => .int,
        .uint => .uint,
        .float => .float,
        .str => .str,
        .bin => .bin,
        .arr => .array,
        .map => .map,
        .ext => .bin,
        .timestamp => .float,
    };
}

export fn colyseus_message_reader_create(data: [*]const u8, len: usize) ?*ReaderWrapper {
    if (len == 0) {
        return createReader(Payload.nilToPayload(), true);
    }

    const data_slice = data[0..len];
    var reader = std.Io.Reader.fixed(data_slice);

    var write_buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buffer);

    var packer = msgpack.PackerIO.init(&reader, &writer);

    const payload = packer.read(allocator) catch {
        return null;
    };

    return createReader(payload, true);
}

export fn colyseus_message_reader_free(wrapper: ?*ReaderWrapper) void {
    if (wrapper == null) return;
    wrapper.?.deinit();
    allocator.destroy(wrapper.?);
}

export fn colyseus_message_reader_get_type(wrapper: ?*ReaderWrapper) ColyseusMessageType {
    if (wrapper == null) return .nil;
    return getPayloadType(wrapper.?.payload);
}

export fn colyseus_message_reader_is_nil(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return true;
    return wrapper.?.payload == .nil;
}

export fn colyseus_message_reader_is_bool(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .bool;
}

export fn colyseus_message_reader_is_int(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .int or wrapper.?.payload == .uint;
}

export fn colyseus_message_reader_is_float(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .float or wrapper.?.payload == .timestamp;
}

export fn colyseus_message_reader_is_str(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .str;
}

export fn colyseus_message_reader_is_bin(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .bin or wrapper.?.payload == .ext;
}

export fn colyseus_message_reader_is_array(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .arr;
}

export fn colyseus_message_reader_is_map(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return wrapper.?.payload == .map;
}

export fn colyseus_message_reader_get_bool(wrapper: ?*ReaderWrapper) bool {
    if (wrapper == null) return false;
    return switch (wrapper.?.payload) {
        .bool => |v| v,
        else => false,
    };
}

export fn colyseus_message_reader_get_int(wrapper: ?*ReaderWrapper) i64 {
    if (wrapper == null) return 0;
    return switch (wrapper.?.payload) {
        .int => |v| v,
        .uint => |v| if (v <= std.math.maxInt(i64)) @intCast(v) else std.math.maxInt(i64),
        .float => |v| @intFromFloat(v),
        else => 0,
    };
}

export fn colyseus_message_reader_get_uint(wrapper: ?*ReaderWrapper) u64 {
    if (wrapper == null) return 0;
    return switch (wrapper.?.payload) {
        .uint => |v| v,
        .int => |v| if (v >= 0) @intCast(v) else 0,
        .float => |v| if (v >= 0) @intFromFloat(v) else 0,
        else => 0,
    };
}

export fn colyseus_message_reader_get_float(wrapper: ?*ReaderWrapper) f64 {
    if (wrapper == null) return 0;
    return switch (wrapper.?.payload) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        .timestamp => |ts| blk: {
            const seconds: f64 = @floatFromInt(ts.seconds);
            const nanos: f64 = @floatFromInt(ts.nanoseconds);
            break :blk seconds + nanos / 1_000_000_000.0;
        },
        else => 0,
    };
}

export fn colyseus_message_reader_get_str(wrapper: ?*ReaderWrapper, out_len: *usize) ?[*]const u8 {
    if (wrapper == null) {
        out_len.* = 0;
        return null;
    }
    return switch (wrapper.?.payload) {
        .str => |s| {
            const val = s.value();
            out_len.* = val.len;
            return val.ptr;
        },
        else => {
            out_len.* = 0;
            return null;
        },
    };
}

export fn colyseus_message_reader_get_bin(wrapper: ?*ReaderWrapper, out_len: *usize) ?[*]const u8 {
    if (wrapper == null) {
        out_len.* = 0;
        return null;
    }
    return switch (wrapper.?.payload) {
        .bin => |b| {
            const val = b.value();
            out_len.* = val.len;
            return val.ptr;
        },
        .ext => |e| {
            out_len.* = e.data.len;
            return e.data.ptr;
        },
        else => {
            out_len.* = 0;
            return null;
        },
    };
}

export fn colyseus_message_reader_get_array_size(wrapper: ?*ReaderWrapper) usize {
    if (wrapper == null) return 0;
    return switch (wrapper.?.payload) {
        .arr => |arr| arr.len,
        else => 0,
    };
}

export fn colyseus_message_reader_get_array_element(wrapper: ?*ReaderWrapper, index: usize) ?*ReaderWrapper {
    if (wrapper == null) return null;
    return switch (wrapper.?.payload) {
        .arr => |arr| {
            if (index >= arr.len) return null;
            return createReader(arr[index], false);
        },
        else => null,
    };
}

export fn colyseus_message_reader_get_map_size(wrapper: ?*ReaderWrapper) usize {
    if (wrapper == null) return 0;
    return switch (wrapper.?.payload) {
        .map => |m| m.count(),
        else => 0,
    };
}

export fn colyseus_message_reader_map_get(wrapper: ?*ReaderWrapper, key: [*c]const u8) ?*ReaderWrapper {
    if (wrapper == null or key == null) return null;
    const key_str = std.mem.span(key);

    return switch (wrapper.?.payload) {
        .map => |m| {
            const key_payload = Payload.strToPayload(key_str, allocator) catch return null;
            defer {
                var kp = key_payload;
                kp.free(allocator);
            }

            if (m.map.get(key_payload)) |value| {
                return createReader(value, false);
            }
            return null;
        },
        else => null,
    };
}

export fn colyseus_message_reader_map_get_str(
    wrapper: ?*ReaderWrapper,
    key: [*c]const u8,
    out_value: *?[*]const u8,
    out_len: *usize,
) bool {
    const sub_reader = colyseus_message_reader_map_get(wrapper, key);
    if (sub_reader == null) {
        out_value.* = null;
        out_len.* = 0;
        return false;
    }
    defer colyseus_message_reader_free(sub_reader);

    out_value.* = colyseus_message_reader_get_str(sub_reader, out_len);
    return out_value.* != null;
}

export fn colyseus_message_reader_map_get_int(
    wrapper: ?*ReaderWrapper,
    key: [*c]const u8,
    out_value: *i64,
) bool {
    const sub_reader = colyseus_message_reader_map_get(wrapper, key);
    if (sub_reader == null) {
        out_value.* = 0;
        return false;
    }
    defer colyseus_message_reader_free(sub_reader);

    if (!colyseus_message_reader_is_int(sub_reader)) {
        out_value.* = 0;
        return false;
    }

    out_value.* = colyseus_message_reader_get_int(sub_reader);
    return true;
}

export fn colyseus_message_reader_map_get_uint(
    wrapper: ?*ReaderWrapper,
    key: [*c]const u8,
    out_value: *u64,
) bool {
    const sub_reader = colyseus_message_reader_map_get(wrapper, key);
    if (sub_reader == null) {
        out_value.* = 0;
        return false;
    }
    defer colyseus_message_reader_free(sub_reader);

    if (!colyseus_message_reader_is_int(sub_reader)) {
        out_value.* = 0;
        return false;
    }

    out_value.* = colyseus_message_reader_get_uint(sub_reader);
    return true;
}

export fn colyseus_message_reader_map_get_float(
    wrapper: ?*ReaderWrapper,
    key: [*c]const u8,
    out_value: *f64,
) bool {
    const sub_reader = colyseus_message_reader_map_get(wrapper, key);
    if (sub_reader == null) {
        out_value.* = 0;
        return false;
    }
    defer colyseus_message_reader_free(sub_reader);

    if (!colyseus_message_reader_is_float(sub_reader) and !colyseus_message_reader_is_int(sub_reader)) {
        out_value.* = 0;
        return false;
    }

    out_value.* = colyseus_message_reader_get_float(sub_reader);
    return true;
}

export fn colyseus_message_reader_map_get_bool(
    wrapper: ?*ReaderWrapper,
    key: [*c]const u8,
    out_value: *bool,
) bool {
    const sub_reader = colyseus_message_reader_map_get(wrapper, key);
    if (sub_reader == null) {
        out_value.* = false;
        return false;
    }
    defer colyseus_message_reader_free(sub_reader);

    if (!colyseus_message_reader_is_bool(sub_reader)) {
        out_value.* = false;
        return false;
    }

    out_value.* = colyseus_message_reader_get_bool(sub_reader);
    return true;
}

const ColyseusMessageMapIterator = extern struct {
    map_reader: ?*ReaderWrapper,
    current_index: usize,
    total_size: usize,
};

export fn colyseus_message_reader_map_iterator(wrapper: ?*ReaderWrapper) ColyseusMessageMapIterator {
    if (wrapper == null) {
        return .{ .map_reader = null, .current_index = 0, .total_size = 0 };
    }

    const size = colyseus_message_reader_get_map_size(wrapper);
    return .{
        .map_reader = wrapper,
        .current_index = 0,
        .total_size = size,
    };
}

export fn colyseus_message_map_iterator_next(
    iter: *ColyseusMessageMapIterator,
    out_key: *?*ReaderWrapper,
    out_value: *?*ReaderWrapper,
) bool {
    out_key.* = null;
    out_value.* = null;

    if (iter.map_reader == null or iter.current_index >= iter.total_size) {
        return false;
    }

    switch (iter.map_reader.?.payload) {
        .map => |m| {
            var it = m.map.iterator();
            var i: usize = 0;
            while (it.next()) |entry| {
                if (i == iter.current_index) {
                    out_key.* = createReader(entry.key_ptr.*, false);
                    out_value.* = createReader(entry.value_ptr.*, false);
                    iter.current_index += 1;
                    return true;
                }
                i += 1;
            }
        },
        else => {},
    }

    return false;
}

const std = @import("std");
const testing = std.testing;
const math = std.math;

const c = @cImport({
    @cInclude("colyseus/client.h");
    @cInclude("colyseus/messages.h");
    @cInclude("schema/my_room_state.h");
    @cInclude("string.h");
});

const TEST_SERVER = "localhost";
const TEST_PORT = "2567";
const TIMEOUT_SECONDS = 10;

var test_passed: c_int = 0;
var test_failed: c_int = 0;
var joined: c_int = 0;
var message_types_received: c_int = 0;
var validation_errors: c_int = 0;

const TypeValidation = struct {
    key: [*c]const u8,
    expected_type: c.colyseus_message_type_t,
};

const type_validations = [_]TypeValidation{
    // Strings
    .{ .key = "string", .expected_type = c.COLYSEUS_MESSAGE_TYPE_STR },
    .{ .key = "emptyString", .expected_type = c.COLYSEUS_MESSAGE_TYPE_STR },
    .{ .key = "unicodeString", .expected_type = c.COLYSEUS_MESSAGE_TYPE_STR },

    // Integers (positive values may be uint, negative are int)
    .{ .key = "positiveInt", .expected_type = c.COLYSEUS_MESSAGE_TYPE_UINT },
    .{ .key = "negativeInt", .expected_type = c.COLYSEUS_MESSAGE_TYPE_INT },
    .{ .key = "zero", .expected_type = c.COLYSEUS_MESSAGE_TYPE_UINT },
    .{ .key = "largeInt", .expected_type = c.COLYSEUS_MESSAGE_TYPE_UINT },
    .{ .key = "smallInt", .expected_type = c.COLYSEUS_MESSAGE_TYPE_INT },

    // Floats
    .{ .key = "float", .expected_type = c.COLYSEUS_MESSAGE_TYPE_FLOAT },
    .{ .key = "negativeFloat", .expected_type = c.COLYSEUS_MESSAGE_TYPE_FLOAT },
    .{ .key = "infinity", .expected_type = c.COLYSEUS_MESSAGE_TYPE_FLOAT },
    .{ .key = "negativeInfinity", .expected_type = c.COLYSEUS_MESSAGE_TYPE_FLOAT },
    .{ .key = "nan", .expected_type = c.COLYSEUS_MESSAGE_TYPE_FLOAT },

    // Booleans
    .{ .key = "boolTrue", .expected_type = c.COLYSEUS_MESSAGE_TYPE_BOOL },
    .{ .key = "boolFalse", .expected_type = c.COLYSEUS_MESSAGE_TYPE_BOOL },

    // Null/Undefined
    .{ .key = "nullValue", .expected_type = c.COLYSEUS_MESSAGE_TYPE_NIL },

    // Arrays
    .{ .key = "emptyArray", .expected_type = c.COLYSEUS_MESSAGE_TYPE_ARRAY },
    .{ .key = "numberArray", .expected_type = c.COLYSEUS_MESSAGE_TYPE_ARRAY },
    .{ .key = "stringArray", .expected_type = c.COLYSEUS_MESSAGE_TYPE_ARRAY },
    .{ .key = "mixedArray", .expected_type = c.COLYSEUS_MESSAGE_TYPE_ARRAY },
    .{ .key = "arrayWithHoles", .expected_type = c.COLYSEUS_MESSAGE_TYPE_ARRAY },

    // Objects/Maps
    .{ .key = "nestedObject", .expected_type = c.COLYSEUS_MESSAGE_TYPE_MAP },
    .{ .key = "emptyObject", .expected_type = c.COLYSEUS_MESSAGE_TYPE_MAP },

    // Binary
    .{ .key = "uint8Array", .expected_type = c.COLYSEUS_MESSAGE_TYPE_BIN },
    .{ .key = "buffer", .expected_type = c.COLYSEUS_MESSAGE_TYPE_BIN },
};

fn onJoin(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    joined = 1;
}

fn onMessageTypes(reader: ?*c.colyseus_message_reader_t, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;

    if (reader == null) {
        std.debug.print("ERROR: message reader is null\n", .{});
        validation_errors += 1;
        message_types_received = 1;
        return;
    }

    // Validate it's a map
    if (!c.colyseus_message_reader_is_map(reader)) {
        std.debug.print("ERROR: expected map at root level\n", .{});
        validation_errors += 1;
        message_types_received = 1;
        return;
    }

    // Validate each type
    for (type_validations) |validation| {
        const sub_reader = c.colyseus_message_reader_map_get(reader, validation.key);
        if (sub_reader == null) {
            std.debug.print("ERROR: key '{s}' not found in message\n", .{std.mem.span(validation.key)});
            validation_errors += 1;
            continue;
        }
        defer c.colyseus_message_reader_free(sub_reader);

        const actual_type = c.colyseus_message_reader_get_type(sub_reader);

        // For integers, both INT and UINT are acceptable for positive numbers
        var type_ok = (actual_type == validation.expected_type);
        if (!type_ok) {
            if ((validation.expected_type == c.COLYSEUS_MESSAGE_TYPE_INT or
                validation.expected_type == c.COLYSEUS_MESSAGE_TYPE_UINT) and
                (actual_type == c.COLYSEUS_MESSAGE_TYPE_INT or
                    actual_type == c.COLYSEUS_MESSAGE_TYPE_UINT))
            {
                type_ok = true;
            }
        }

        if (!type_ok) {
            std.debug.print("ERROR: key '{s}' expected type {d}, got {d}\n", .{
                std.mem.span(validation.key),
                validation.expected_type,
                actual_type,
            });
            validation_errors += 1;
        }
    }

    // Validate string values
    validateStringValue(reader, "string", "hello world");
    validateStringValue(reader, "emptyString", "");
    validateStringContains(reader, "unicodeString", "こんにちは");

    // Validate integer values
    validateIntValue(reader, "positiveInt", 42);
    validateIntValue(reader, "negativeInt", -123);
    validateIntValue(reader, "zero", 0);
    validateIntValue(reader, "largeInt", 2147483647);
    validateIntValue(reader, "smallInt", -2147483648);

    // Validate float values
    validateFloatApprox(reader, "float", 3.14159, 0.0001);
    validateFloatApprox(reader, "negativeFloat", -2.71828, 0.0001);

    // Validate special float values (Infinity, -Infinity, NaN)
    validateSpecialFloats(reader);

    // Validate boolean values
    validateBoolValue(reader, "boolTrue", true);
    validateBoolValue(reader, "boolFalse", false);

    // Validate arrays
    validateArraySize(reader, "emptyArray", 0);
    validateArraySize(reader, "numberArray", 5);
    validateArraySize(reader, "stringArray", 3);
    validateArraySize(reader, "mixedArray", 6);

    // Validate nested object access
    validateNestedObject(reader);

    // Validate binary data
    validateBinaryData(reader);

    message_types_received = 1;
}

fn validateStringValue(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, expected: []const u8) void {
    var out_value: ?[*]const u8 = null;
    var out_len: usize = 0;
    if (c.colyseus_message_reader_map_get_str(reader, key, &out_value, &out_len)) {
        if (out_value) |val| {
            const actual = val[0..out_len];
            if (!std.mem.eql(u8, actual, expected)) {
                std.debug.print("ERROR: '{s}' expected '{s}', got '{s}'\n", .{ std.mem.span(key), expected, actual });
                validation_errors += 1;
            }
        }
    } else {
        std.debug.print("ERROR: could not get string value for '{s}'\n", .{std.mem.span(key)});
        validation_errors += 1;
    }
}

fn validateStringContains(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, substring: []const u8) void {
    var out_value: ?[*]const u8 = null;
    var out_len: usize = 0;
    if (c.colyseus_message_reader_map_get_str(reader, key, &out_value, &out_len)) {
        if (out_value) |val| {
            const actual = val[0..out_len];
            if (std.mem.indexOf(u8, actual, substring) == null) {
                std.debug.print("ERROR: '{s}' expected to contain '{s}', got '{s}'\n", .{ std.mem.span(key), substring, actual });
                validation_errors += 1;
            }
        }
    } else {
        std.debug.print("ERROR: could not get string value for '{s}'\n", .{std.mem.span(key)});
        validation_errors += 1;
    }
}

fn validateIntValue(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, expected: i64) void {
    var out_value: i64 = 0;
    if (c.colyseus_message_reader_map_get_int(reader, key, &out_value)) {
        if (out_value != expected) {
            std.debug.print("ERROR: '{s}' expected {d}, got {d}\n", .{ std.mem.span(key), expected, out_value });
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get int value for '{s}'\n", .{std.mem.span(key)});
        validation_errors += 1;
    }
}

fn validateFloatApprox(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, expected: f64, tolerance: f64) void {
    var out_value: f64 = 0;
    if (c.colyseus_message_reader_map_get_float(reader, key, &out_value)) {
        if (@abs(out_value - expected) > tolerance) {
            std.debug.print("ERROR: '{s}' expected ~{d}, got {d}\n", .{ std.mem.span(key), expected, out_value });
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get float value for '{s}'\n", .{std.mem.span(key)});
        validation_errors += 1;
    }
}

fn validateSpecialFloats(reader: ?*c.colyseus_message_reader_t) void {
    // Validate Infinity
    var inf_value: f64 = 0;
    if (c.colyseus_message_reader_map_get_float(reader, "infinity", &inf_value)) {
        if (!math.isPositiveInf(inf_value)) {
            std.debug.print("ERROR: 'infinity' expected +Inf, got {d}\n", .{inf_value});
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get float value for 'infinity'\n", .{});
        validation_errors += 1;
    }

    // Validate -Infinity
    var neg_inf_value: f64 = 0;
    if (c.colyseus_message_reader_map_get_float(reader, "negativeInfinity", &neg_inf_value)) {
        if (!math.isNegativeInf(neg_inf_value)) {
            std.debug.print("ERROR: 'negativeInfinity' expected -Inf, got {d}\n", .{neg_inf_value});
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get float value for 'negativeInfinity'\n", .{});
        validation_errors += 1;
    }

    // Validate NaN
    var nan_value: f64 = 0;
    if (c.colyseus_message_reader_map_get_float(reader, "nan", &nan_value)) {
        if (!math.isNan(nan_value)) {
            std.debug.print("ERROR: 'nan' expected NaN, got {d}\n", .{nan_value});
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get float value for 'nan'\n", .{});
        validation_errors += 1;
    }
}

fn validateBoolValue(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, expected: bool) void {
    var out_value: bool = false;
    if (c.colyseus_message_reader_map_get_bool(reader, key, &out_value)) {
        if (out_value != expected) {
            std.debug.print("ERROR: '{s}' expected {}, got {}\n", .{ std.mem.span(key), expected, out_value });
            validation_errors += 1;
        }
    } else {
        std.debug.print("ERROR: could not get bool value for '{s}'\n", .{std.mem.span(key)});
        validation_errors += 1;
    }
}

fn validateArraySize(reader: ?*c.colyseus_message_reader_t, key: [*c]const u8, expected_size: usize) void {
    const sub_reader = c.colyseus_message_reader_map_get(reader, key);
    if (sub_reader == null) {
        std.debug.print("ERROR: key '{s}' not found\n", .{std.mem.span(key)});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(sub_reader);

    const actual_size = c.colyseus_message_reader_get_array_size(sub_reader);
    if (actual_size != expected_size) {
        std.debug.print("ERROR: '{s}' expected size {d}, got {d}\n", .{ std.mem.span(key), expected_size, actual_size });
        validation_errors += 1;
    }
}

fn validateNestedObject(reader: ?*c.colyseus_message_reader_t) void {
    // Get nestedObject
    const nested = c.colyseus_message_reader_map_get(reader, "nestedObject");
    if (nested == null) {
        std.debug.print("ERROR: 'nestedObject' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(nested);

    // Get level1
    const level1 = c.colyseus_message_reader_map_get(nested, "level1");
    if (level1 == null) {
        std.debug.print("ERROR: 'nestedObject.level1' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(level1);

    // Get level2
    const level2 = c.colyseus_message_reader_map_get(level1, "level2");
    if (level2 == null) {
        std.debug.print("ERROR: 'nestedObject.level1.level2' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(level2);

    // Get level3
    const level3 = c.colyseus_message_reader_map_get(level2, "level3");
    if (level3 == null) {
        std.debug.print("ERROR: 'nestedObject.level1.level2.level3' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(level3);

    // Validate the deep value
    var out_value: ?[*]const u8 = null;
    var out_len: usize = 0;
    if (c.colyseus_message_reader_map_get_str(level3, "deep", &out_value, &out_len)) {
        if (out_value) |val| {
            const actual = val[0..out_len];
            if (!std.mem.eql(u8, actual, "value")) {
                std.debug.print("ERROR: 'nestedObject...deep' expected 'value', got '{s}'\n", .{actual});
                validation_errors += 1;
            }
        }
    } else {
        std.debug.print("ERROR: could not get 'nestedObject.level1.level2.level3.deep'\n", .{});
        validation_errors += 1;
    }
}

fn validateBinaryData(reader: ?*c.colyseus_message_reader_t) void {
    // Validate uint8Array: [0, 1, 2, 255, 128, 64]
    const uint8_reader = c.colyseus_message_reader_map_get(reader, "uint8Array");
    if (uint8_reader == null) {
        std.debug.print("ERROR: 'uint8Array' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(uint8_reader);

    var bin_len: usize = 0;
    const bin_data = c.colyseus_message_reader_get_bin(uint8_reader, &bin_len);
    if (bin_data == null) {
        std.debug.print("ERROR: could not get binary data for 'uint8Array'\n", .{});
        validation_errors += 1;
        return;
    }

    const expected_bytes = [_]u8{ 0, 1, 2, 255, 128, 64 };
    if (bin_len != expected_bytes.len) {
        std.debug.print("ERROR: 'uint8Array' expected length {d}, got {d}\n", .{ expected_bytes.len, bin_len });
        validation_errors += 1;
        return;
    }

    const actual_bytes = bin_data[0..bin_len];
    if (!std.mem.eql(u8, actual_bytes, &expected_bytes)) {
        std.debug.print("ERROR: 'uint8Array' data mismatch\n", .{});
        validation_errors += 1;
    }

    // Validate buffer: [10, 20, 30, 40, 50]
    const buffer_reader = c.colyseus_message_reader_map_get(reader, "buffer");
    if (buffer_reader == null) {
        std.debug.print("ERROR: 'buffer' not found\n", .{});
        validation_errors += 1;
        return;
    }
    defer c.colyseus_message_reader_free(buffer_reader);

    var buffer_len: usize = 0;
    const buffer_data = c.colyseus_message_reader_get_bin(buffer_reader, &buffer_len);
    if (buffer_data == null) {
        std.debug.print("ERROR: could not get binary data for 'buffer'\n", .{});
        validation_errors += 1;
        return;
    }

    const expected_buffer = [_]u8{ 10, 20, 30, 40, 50 };
    if (buffer_len != expected_buffer.len) {
        std.debug.print("ERROR: 'buffer' expected length {d}, got {d}\n", .{ expected_buffer.len, buffer_len });
        validation_errors += 1;
        return;
    }

    const actual_buffer = buffer_data[0..buffer_len];
    if (!std.mem.eql(u8, actual_buffer, &expected_buffer)) {
        std.debug.print("ERROR: 'buffer' data mismatch\n", .{});
        validation_errors += 1;
    }
}

fn onRoomError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    std.debug.print("Room error: code={d}, message={s}\n", .{ code, std.mem.span(message) });
    test_failed = 1;
}

fn onLeave(code: c_int, reason: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = code;
    _ = reason;
    _ = userdata;
}

fn onError(code: c_int, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    std.debug.print("Client error: code={d}, message={s}\n", .{ code, std.mem.span(message) });
    test_failed = 1;
}

fn onRoomSuccess(room: [*c]c.colyseus_room_t, userdata: ?*anyopaque) callconv(.c) void {
    c.colyseus_room_set_state_type(room, &c.my_room_state_vtable);

    c.colyseus_room_on_join(room, onJoin, null);
    c.colyseus_room_on_message(room, "message_types", onMessageTypes, null);
    c.colyseus_room_on_error(room, onRoomError, null);
    c.colyseus_room_on_leave(room, onLeave, null);

    const room_ptr: *?[*c]c.colyseus_room_t = @ptrCast(@alignCast(userdata));
    room_ptr.* = room;

    test_passed = 1;
}

test "messages: send and receive message types" {
    // Reset state
    test_passed = 0;
    test_failed = 0;
    joined = 0;
    message_types_received = 0;
    validation_errors = 0;

    const settings = c.colyseus_settings_create();
    defer c.colyseus_settings_free(settings);

    c.colyseus_settings_set_address(settings, TEST_SERVER);
    c.colyseus_settings_set_port(settings, TEST_PORT);

    const client = c.colyseus_client_create(settings);
    defer c.colyseus_client_free(client);

    if (client == null) {
        return error.ClientCreationFailed;
    }

    var room: ?[*c]c.colyseus_room_t = null;

    c.colyseus_client_join_or_create(
        client,
        "stub_room",
        "{}",
        onRoomSuccess,
        onError,
        &room,
    );

    // Wait for connection
    var wait_count: usize = 0;
    while (joined == 0 and test_failed == 0 and wait_count < 100) : (wait_count += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expect(joined == 1);
    try testing.expect(room != null);

    // Send test_message_types to trigger the server response
    const msg = c.colyseus_message_nil_create();
    defer c.colyseus_message_free(msg);
    c.colyseus_room_send(room.?, "test_message_types", msg);

    // Wait for message_types response
    wait_count = 0;
    while (message_types_received == 0 and test_failed == 0 and wait_count < 100) : (wait_count += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expect(message_types_received == 1);
    try testing.expectEqual(@as(c_int, 0), validation_errors);

    // Cleanup
    c.colyseus_room_leave(room.?, true);
    defer c.colyseus_room_free(room.?);

    std.Thread.sleep(50 * std.time.ns_per_ms);
}

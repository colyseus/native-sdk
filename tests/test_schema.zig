const std = @import("std");
const testing = std.testing;

// ============================================================================
// C bindings for schema types
// ============================================================================

const c = @cImport({
    @cInclude("colyseus/schema/types.h");
    @cInclude("colyseus/schema/decode.h");
});

// ============================================================================
// Test helpers
// ============================================================================

fn expectEqualStrings(expected: []const u8, actual: [*c]const u8) !void {
    if (actual == null) {
        return error.NullPointer;
    }
    const actual_slice = std.mem.span(actual);
    try testing.expectEqualStrings(expected, actual_slice);
}

// ============================================================================
// Decode primitive tests
// ============================================================================

test "decode_uint8" {
    const bytes = [_]u8{0x42};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_uint8(&bytes, &it);

    try testing.expectEqual(@as(u8, 0x42), result);
    try testing.expectEqual(@as(c_int, 1), it.offset);
}

test "decode_int8_positive" {
    const bytes = [_]u8{0x7F};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_int8(&bytes, &it);

    try testing.expectEqual(@as(i8, 127), result);
}

test "decode_int8_negative" {
    const bytes = [_]u8{0xFF};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_int8(&bytes, &it);

    try testing.expectEqual(@as(i8, -1), result);
}

test "decode_uint16" {
    // Little-endian: 0x0102 = 258
    const bytes = [_]u8{ 0x02, 0x01 };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_uint16(&bytes, &it);

    try testing.expectEqual(@as(u16, 258), result);
    try testing.expectEqual(@as(c_int, 2), it.offset);
}

test "decode_int16" {
    // Little-endian: -1 = 0xFFFF
    const bytes = [_]u8{ 0xFF, 0xFF };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_int16(&bytes, &it);

    try testing.expectEqual(@as(i16, -1), result);
}

test "decode_uint32" {
    // Little-endian: 0x01020304 = 16909060
    const bytes = [_]u8{ 0x04, 0x03, 0x02, 0x01 };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_uint32(&bytes, &it);

    try testing.expectEqual(@as(u32, 16909060), result);
    try testing.expectEqual(@as(c_int, 4), it.offset);
}

test "decode_int32" {
    // Little-endian: -1
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_int32(&bytes, &it);

    try testing.expectEqual(@as(i32, -1), result);
}

test "decode_float32" {
    // IEEE 754: 1.0f = 0x3F800000
    const bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3F };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_float32(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.0001);
}

test "decode_float64" {
    // IEEE 754: 1.0 = 0x3FF0000000000000
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_float64(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f64, 1.0), result, 0.0001);
}

test "decode_boolean_true" {
    const bytes = [_]u8{0x01};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_boolean(&bytes, &it);

    try testing.expect(result);
}

test "decode_boolean_false" {
    const bytes = [_]u8{0x00};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_boolean(&bytes, &it);

    try testing.expect(!result);
}

// ============================================================================
// Decode number (msgpack format) tests
// ============================================================================

test "decode_number_positive_fixint" {
    // Positive fixint: 0x00-0x7F
    const bytes = [_]u8{0x2A}; // 42
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_number(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, 42.0), result, 0.0001);
}

test "decode_number_negative_fixint" {
    // Negative fixint: 0xE0-0xFF (-1 to -32)
    const bytes = [_]u8{0xFF}; // -1
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_number(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, -1.0), result, 0.0001);
}

test "decode_number_uint8" {
    // 0xCC prefix + uint8
    const bytes = [_]u8{ 0xCC, 0xFF }; // 255
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_number(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, 255.0), result, 0.0001);
}

test "decode_number_uint16" {
    // 0xCD prefix + uint16 LE
    const bytes = [_]u8{ 0xCD, 0x00, 0x01 }; // 256
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_number(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, 256.0), result, 0.0001);
}

test "decode_number_float32" {
    // 0xCA prefix + float32 LE (1.5)
    const bytes = [_]u8{ 0xCA, 0x00, 0x00, 0xC0, 0x3F };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_number(&bytes, &it);

    try testing.expectApproxEqAbs(@as(f32, 1.5), result, 0.0001);
}

// ============================================================================
// Decode string tests
// ============================================================================

test "decode_string_fixstr" {
    // fixstr: 0xA0-0xBF, length in low 5 bits
    // 0xA5 = 0xA0 | 5, followed by "hello"
    const bytes = [_]u8{ 0xA5, 'h', 'e', 'l', 'l', 'o' };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_string(&bytes, &it);
    defer std.c.free(result);

    try testing.expect(result != null);
    try expectEqualStrings("hello", result);
    try testing.expectEqual(@as(c_int, 6), it.offset);
}

test "decode_string_str8" {
    // str8: 0xD9 prefix + 1-byte length
    const bytes = [_]u8{ 0xD9, 0x05, 'w', 'o', 'r', 'l', 'd' };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_string(&bytes, &it);
    defer std.c.free(result);

    try testing.expect(result != null);
    try expectEqualStrings("world", result);
}

test "decode_string_empty" {
    // fixstr with length 0
    const bytes = [_]u8{0xA0};
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const result = c.colyseus_decode_string(&bytes, &it);
    defer std.c.free(result);

    try testing.expect(result != null);
    try expectEqualStrings("", result);
}

// ============================================================================
// Iterator offset tests
// ============================================================================

test "iterator_multiple_decodes" {
    // Decode multiple values sequentially
    const bytes = [_]u8{
        0x01, // uint8: 1
        0x02, // uint8: 2
        0x03, // uint8: 3
    };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const v1 = c.colyseus_decode_uint8(&bytes, &it);
    try testing.expectEqual(@as(u8, 1), v1);
    try testing.expectEqual(@as(c_int, 1), it.offset);

    const v2 = c.colyseus_decode_uint8(&bytes, &it);
    try testing.expectEqual(@as(u8, 2), v2);
    try testing.expectEqual(@as(c_int, 2), it.offset);

    const v3 = c.colyseus_decode_uint8(&bytes, &it);
    try testing.expectEqual(@as(u8, 3), v3);
    try testing.expectEqual(@as(c_int, 3), it.offset);
}

test "iterator_mixed_types" {
    // uint8 + uint16 LE + uint8
    const bytes = [_]u8{
        0xFF, // uint8: 255
        0x34, 0x12, // uint16 LE: 0x1234 = 4660
        0xAB, // uint8: 171
    };
    var it = c.colyseus_iterator_t{ .offset = 0 };

    const v1 = c.colyseus_decode_uint8(&bytes, &it);
    try testing.expectEqual(@as(u8, 255), v1);

    const v2 = c.colyseus_decode_uint16(&bytes, &it);
    try testing.expectEqual(@as(u16, 0x1234), v2);

    const v3 = c.colyseus_decode_uint8(&bytes, &it);
    try testing.expectEqual(@as(u8, 0xAB), v3);

    try testing.expectEqual(@as(c_int, 4), it.offset);
}

// ============================================================================
// Switch check test
// ============================================================================

test "decode_switch_check" {
    const bytes_with_switch = [_]u8{ 0xFF, 0x00 };
    var it1 = c.colyseus_iterator_t{ .offset = 0 };
    try testing.expect(c.colyseus_decode_switch_check(&bytes_with_switch, &it1));

    const bytes_without_switch = [_]u8{ 0xFE, 0x00 };
    var it2 = c.colyseus_iterator_t{ .offset = 0 };
    try testing.expect(!c.colyseus_decode_switch_check(&bytes_without_switch, &it2));
}

// ============================================================================
// Operation code tests
// ============================================================================

test "operation_codes_defined" {
    try testing.expectEqual(@as(c_int, 128), c.COLYSEUS_OP_ADD);
    try testing.expectEqual(@as(c_int, 0), c.COLYSEUS_OP_REPLACE);
    try testing.expectEqual(@as(c_int, 64), c.COLYSEUS_OP_DELETE);
    try testing.expectEqual(@as(c_int, 192), c.COLYSEUS_OP_DELETE_AND_ADD);
    try testing.expectEqual(@as(c_int, 10), c.COLYSEUS_OP_CLEAR);
}

test "special_bytes_defined" {
    try testing.expectEqual(@as(c_int, 255), c.COLYSEUS_SPEC_SWITCH_TO_STRUCTURE);
    try testing.expectEqual(@as(c_int, 213), c.COLYSEUS_SPEC_TYPE_ID);
}

// ============================================================================
// Field type enum tests
// ============================================================================

test "field_types_defined" {
    try testing.expectEqual(@as(c_uint, 0), c.COLYSEUS_FIELD_STRING);
    try testing.expectEqual(@as(c_uint, 1), c.COLYSEUS_FIELD_NUMBER);
    try testing.expectEqual(@as(c_uint, 2), c.COLYSEUS_FIELD_BOOLEAN);
    try testing.expectEqual(@as(c_uint, 13), c.COLYSEUS_FIELD_REF);
    try testing.expectEqual(@as(c_uint, 14), c.COLYSEUS_FIELD_ARRAY);
    try testing.expectEqual(@as(c_uint, 15), c.COLYSEUS_FIELD_MAP);
}

// ============================================================================
// Number check test
// ============================================================================

test "decode_number_check" {
    // Positive fixint should be a number
    const bytes_fixint = [_]u8{0x42};
    var it1 = c.colyseus_iterator_t{ .offset = 0 };
    try testing.expect(c.colyseus_decode_number_check(&bytes_fixint, &it1));

    // Float32 prefix should be a number
    const bytes_float = [_]u8{0xCA};
    var it2 = c.colyseus_iterator_t{ .offset = 0 };
    try testing.expect(c.colyseus_decode_number_check(&bytes_float, &it2));

    // String prefix should not be a number
    const bytes_string = [_]u8{0xA5};
    var it3 = c.colyseus_iterator_t{ .offset = 0 };
    try testing.expect(!c.colyseus_decode_number_check(&bytes_string, &it3));
}
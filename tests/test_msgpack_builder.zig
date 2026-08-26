const std = @import("std");
const testing = std.testing;

// ============================================================================
// Message builder ownership (offline)
//
// The builder hands its payload out in two different ways, and getting either
// wrong shows up as a double free in whichever binding trusted the header:
//
//   nesting  — put_msg/push_msg ADOPT the child, so the parent is the only
//              owner left and freeing the child is a no-op
//   encoding — leaves the message intact, and the bytes belong to the caller
//
// Every test here frees everything it allocates: run under a debug build and
// a leak or a second free aborts the process.
// ============================================================================

const c = @cImport({
    @cInclude("colyseus/messages.h");
});

fn encode(msg: *c.colyseus_message_t) []const u8 {
    var len: usize = 0;
    const data = c.colyseus_message_encode(msg, &len);
    if (data == null) return &[_]u8{};
    return data[0..len];
}

fn expectEncodes(msg: *c.colyseus_message_t, expected: []const u8) !void {
    const bytes = encode(msg);
    defer c.colyseus_message_encoded_free(@constCast(bytes.ptr), bytes.len);
    try testing.expectEqualSlices(u8, expected, bytes);
}

// ============================================================================
// Encoding
// ============================================================================

test "encode returns a caller-owned buffer" {
    const msg = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(msg);
    c.colyseus_message_map_put_int(msg, "n", 7);

    var len: usize = 0;
    const data = c.colyseus_message_encode(msg, &len);
    try testing.expect(data != null);
    try testing.expect(len > 0);

    // Freeing the buffer must not disturb the message it came from.
    c.colyseus_message_encoded_free(data, len);
    try expectEncodes(msg, "\x81\xa1n\x07");
}

test "encode does not consume the message" {
    const msg = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(msg);
    c.colyseus_message_map_put_str(msg, "hello", "world");

    // Same bytes three times: encoding is a copy, not a hand-off.
    try expectEncodes(msg, "\x81\xa5hello\xa5world");
    try expectEncodes(msg, "\x81\xa5hello\xa5world");
    try expectEncodes(msg, "\x81\xa5hello\xa5world");
}

test "encode does not consume an array message" {
    const msg = c.colyseus_message_array_create().?;
    defer c.colyseus_message_free(msg);
    c.colyseus_message_array_push_int(msg, 1);
    c.colyseus_message_array_push_str(msg, "two");

    try expectEncodes(msg, "\x92\x01\xa3two");
    try expectEncodes(msg, "\x92\x01\xa3two");
}

test "encode of a primitive message" {
    const msg = c.colyseus_message_str_create("hi").?;
    defer c.colyseus_message_free(msg);
    try expectEncodes(msg, "\xa2hi");
    try expectEncodes(msg, "\xa2hi");
}

test "encoded_free tolerates null and zero length" {
    c.colyseus_message_encoded_free(null, 0);
    c.colyseus_message_encoded_free(null, 16);
}

// ============================================================================
// Nesting
// ============================================================================

test "map_put_msg adopts the child" {
    const parent = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(parent);

    const child = c.colyseus_message_map_create().?;
    c.colyseus_message_map_put_int(child, "x", 1);
    c.colyseus_message_map_put_msg(parent, "child", child);

    // The child is an empty shell now — freeing it must not touch what the
    // parent adopted.
    c.colyseus_message_free(child);

    try expectEncodes(parent, "\x81\xa5child\x81\xa1x\x01");
}

test "array_push_msg adopts the child" {
    const parent = c.colyseus_message_array_create().?;
    defer c.colyseus_message_free(parent);

    const child = c.colyseus_message_array_create().?;
    c.colyseus_message_array_push_int(child, 42);
    c.colyseus_message_array_push_msg(parent, child);
    c.colyseus_message_free(child);

    try expectEncodes(parent, "\x91\x91\x2a");
}

test "an adopted child leaves nothing behind to nest twice" {
    const first = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(first);
    const second = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(second);

    const child = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(child);
    c.colyseus_message_map_put_int(child, "x", 1);

    c.colyseus_message_map_put_msg(first, "c", child);
    c.colyseus_message_map_put_msg(second, "c", child);

    try expectEncodes(first, "\x81\xa1c\x81\xa1x\x01");
    // The second put found an empty child and stored nothing.
    try expectEncodes(second, "\x80");
}

test "nesting an array inside a map moves its elements" {
    const parent = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(parent);

    const list = c.colyseus_message_array_create().?;
    c.colyseus_message_array_push_str(list, "a");
    c.colyseus_message_array_push_str(list, "b");
    c.colyseus_message_map_put_msg(parent, "list", list);
    c.colyseus_message_free(list);

    try expectEncodes(parent, "\x81\xa4list\x92\xa1a\xa1b");
}

test "deeply nested builders survive an encode and a free" {
    const root = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(root);

    const level1 = c.colyseus_message_map_create().?;
    const level2 = c.colyseus_message_array_create().?;
    const level3 = c.colyseus_message_map_create().?;

    c.colyseus_message_map_put_str(level3, "deep", "value");
    c.colyseus_message_array_push_msg(level2, level3);
    c.colyseus_message_map_put_msg(level1, "arr", level2);
    c.colyseus_message_map_put_msg(root, "obj", level1);

    c.colyseus_message_free(level3);
    c.colyseus_message_free(level2);
    c.colyseus_message_free(level1);

    try expectEncodes(root, "\x81\xa3obj\x81\xa3arr\x91\x81\xa4deep\xa5value");
    try expectEncodes(root, "\x81\xa3obj\x81\xa3arr\x91\x81\xa4deep\xa5value");
}

// ============================================================================
// Value coverage
// ============================================================================

test "map holds every scalar kind" {
    const msg = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(msg);

    c.colyseus_message_map_put_str(msg, "s", "x");
    c.colyseus_message_map_put_int(msg, "i", -1);
    c.colyseus_message_map_put_uint(msg, "u", 300);
    c.colyseus_message_map_put_float(msg, "f", 0.5);
    c.colyseus_message_map_put_bool(msg, "b", true);
    c.colyseus_message_map_put_nil(msg, "n");

    const bytes = encode(msg);
    defer c.colyseus_message_encoded_free(@constCast(bytes.ptr), bytes.len);
    try testing.expect(bytes.len > 0);
    try testing.expectEqual(@as(u8, 0x86), bytes[0]); // fixmap, 6 entries
}

test "array holds every scalar kind" {
    const msg = c.colyseus_message_array_create().?;
    defer c.colyseus_message_free(msg);

    c.colyseus_message_array_push_str(msg, "x");
    c.colyseus_message_array_push_int(msg, -1);
    c.colyseus_message_array_push_uint(msg, 300);
    c.colyseus_message_array_push_float(msg, 0.5);
    c.colyseus_message_array_push_bool(msg, false);
    c.colyseus_message_array_push_nil(msg);

    const bytes = encode(msg);
    defer c.colyseus_message_encoded_free(@constCast(bytes.ptr), bytes.len);
    try testing.expectEqual(@as(u8, 0x96), bytes[0]); // fixarray, 6 entries
}

test "null arguments are ignored" {
    c.colyseus_message_map_put_int(null, "k", 1);
    c.colyseus_message_array_push_int(null, 1);
    c.colyseus_message_map_put_msg(null, "k", null);
    c.colyseus_message_array_push_msg(null, null);
    c.colyseus_message_free(null);

    var len: usize = 123;
    try testing.expect(c.colyseus_message_encode(null, &len) == null);
    try testing.expectEqual(@as(usize, 0), len);
}

test "put_msg onto a message that is not a map is ignored" {
    const arr = c.colyseus_message_array_create().?;
    defer c.colyseus_message_free(arr);

    const child = c.colyseus_message_map_create().?;
    defer c.colyseus_message_free(child);
    c.colyseus_message_map_put_int(child, "x", 1);

    c.colyseus_message_map_put_msg(arr, "k", child);

    // Rejected before the child was touched, so it still holds its value.
    try expectEncodes(arr, "\x90");
    try expectEncodes(child, "\x81\xa1x\x01");
}

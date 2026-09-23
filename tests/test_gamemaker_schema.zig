// Bridge tests for the GameMaker schema-callback layer (gm_snapshot_value and
// the handle layer of platforms/gamemaker/src/gamemaker_export.c, compiled
// into this exe).
//
// The trampolines that flatten a decoded field into GML event slots are only
// reachable from GML through a joined room, so the end-to-end path needs a
// live server. These drive the flattening helper directly instead — it is the
// piece with per-type pointer writes, and the piece that crashed.

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/schema/types.h");
    @cInclude("gamemaker_internal.h");
});

test "gm_snapshot_value leaves every slot alone for a deleted field" {
    // A DELETE delivers value = NULL — the early return keeps the caller's
    // zeroed slots, which is how GML reads "no value".
    var number: f64 = 7;
    var string = std.mem.zeroes([64]u8);

    c.gm_snapshot_value(c.COLYSEUS_FIELD_NUMBER, null, &number, &string, string.len);
    c.gm_snapshot_value(c.COLYSEUS_FIELD_STRING, null, &number, &string, string.len);

    try testing.expectEqual(@as(f64, 7), number);
    try testing.expectEqual(@as(u8, 0), string[0]);
}

test "gm_snapshot_value flattens primitives and strings" {
    var number: f64 = 0;
    var string = std.mem.zeroes([64]u8);

    var f: f32 = 1.5;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_FLOAT32, &f, &number, &string, string.len);
    try testing.expectEqual(@as(f64, 1.5), number);

    var i: i16 = -300;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_INT16, &i, &number, &string, string.len);
    try testing.expectEqual(@as(f64, -300), number);

    var b: bool = true;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_BOOLEAN, &b, &number, &string, string.len);
    try testing.expectEqual(@as(f64, 1), number);

    var text = [_]u8{ 'h', 'i', 0 };
    c.gm_snapshot_value(c.COLYSEUS_FIELD_STRING, &text, &number, &string, string.len);
    try testing.expectEqualStrings("hi", std.mem.sliceTo(&string, 0));
}

// ── handles ─────────────────────────────────────────────────────────────

var objects: [4]u64 = .{ 0, 0, 0, 0 };

test "handles round-trip and stay clear of room refs" {
    const a = c.gm_handle_put(&objects[0], c.GM_HANDLE_CLIENT, 0);
    defer c.gm_handle_drop_ptr(&objects[0]);

    try testing.expect(a > c.GM_MAX_ROOM_REFS and a < 2147483648.0);
    try testing.expectEqual(@floor(a), a);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&objects[0])), c.gm_handle_get(a, c.GM_HANDLE_CLIENT));
    // the same object keeps its handle — GML caches structs by it
    try testing.expectEqual(a, c.gm_handle_put(&objects[0], c.GM_HANDLE_CLIENT, 0));
    // a handle never resolves as another kind
    try testing.expect(c.gm_handle_get(a, c.GM_HANDLE_MESSAGE) == null);
    try testing.expect(c.gm_handle_get(0, c.GM_HANDLE_CLIENT) == null);
    try testing.expect(c.gm_handle_get(a + 0.5, c.GM_HANDLE_CLIENT) == null);
}

test "a dropped handle stays dead after its slot is reused" {
    const old = c.gm_handle_put(&objects[1], c.GM_HANDLE_MESSAGE, 0);
    c.gm_handle_drop_ptr(&objects[1]);
    try testing.expect(c.gm_handle_get(old, c.GM_HANDLE_MESSAGE) == null);

    const new = c.gm_handle_put(&objects[2], c.GM_HANDLE_MESSAGE, 0);
    defer c.gm_handle_drop_ptr(&objects[2]);
    try testing.expect(new != old);
    try testing.expect(c.gm_handle_get(old, c.GM_HANDLE_MESSAGE) == null);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&objects[2])), c.gm_handle_get(new, c.GM_HANDLE_MESSAGE));
}

// https://github.com/colyseus/native-sdk/issues/32 — Android arm64 hands out
// heap pointers tagged 0xb4 in the top byte. As a double one loses its low
// bits; as a handle it comes back exact.
test "a tagged heap pointer survives as a handle" {
    const tagged: usize = @intFromPtr(&objects[3]) | (@as(usize, 0xb4) << 56);
    if (@sizeOf(usize) < 8) return error.SkipZigTest;

    const as_double: f64 = @floatFromInt(tagged);
    try testing.expect(@as(u64, @intFromFloat(as_double)) != tagged);

    const ptr: *anyopaque = @ptrFromInt(tagged);
    const handle = c.gm_handle_put(ptr, c.GM_HANDLE_SCHEMA, 0);
    defer c.gm_handle_drop_ptr(ptr);
    try testing.expectEqual(tagged, @intFromPtr(c.gm_schema_resolve(handle).?));
}

test "instances outside a room get slot handles, and so do their children" {
    var parent = std.mem.zeroes(c.colyseus_schema_t);
    var child = std.mem.zeroes(c.colyseus_schema_t);
    parent.__refId = 3;
    child.__refId = 4;
    defer c.gm_handle_drop_ptr(&parent);
    defer c.gm_handle_drop_ptr(&child);

    const ph = c.gm_schema_handle(0, &parent);
    try testing.expect(ph > 0 and ph < 4294967296.0);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&parent)), c.gm_schema_resolve(ph));

    const ch = c.gm_schema_child_handle(ph, &child);
    try testing.expect(ch > 0 and ch < 4294967296.0);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&child)), c.gm_schema_resolve(ch));
    try testing.expectEqual(@as(f64, 0), c.gm_schema_child_handle(ph, null));
}

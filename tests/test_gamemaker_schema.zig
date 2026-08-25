// Bridge tests for the GameMaker schema-callback layer (the gm_snapshot_value
// half of platforms/gamemaker/src/gamemaker_export.c, compiled into this exe).
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

// A ref field's "instance" is only ever a pointer flattened to a double; the
// helper never dereferences it, so a sentinel address is enough.
const FAKE_INSTANCE: usize = 0xC0FFEE;

test "gm_snapshot_value tolerates a missing instance slot" {
    // gm_property_change_trampoline snapshots previous_value with
    // out_instance = NULL: the event carries prev_value_number and
    // prev_value_string, but has no prev instance slot. Writing the ref
    // through unconditionally was a NULL-pointer write on every ref-field
    // change that had a previous value.
    var number: f64 = 0;
    var string = std.mem.zeroes([64]u8);

    c.gm_snapshot_value(
        c.COLYSEUS_FIELD_REF,
        @ptrFromInt(FAKE_INSTANCE),
        &number,
        &string,
        string.len,
        null,
    );

    // reaching here at all is the assertion; the slots stay untouched
    try testing.expectEqual(@as(f64, 0), number);
    try testing.expectEqual(@as(u8, 0), string[0]);
}

test "gm_snapshot_value writes the instance when the slot is present" {
    var number: f64 = 0;
    var instance: f64 = 0;
    var string = std.mem.zeroes([64]u8);

    c.gm_snapshot_value(
        c.COLYSEUS_FIELD_REF,
        @ptrFromInt(FAKE_INSTANCE),
        &number,
        &string,
        string.len,
        &instance,
    );

    try testing.expectEqual(@as(f64, @floatFromInt(FAKE_INSTANCE)), instance);
}

test "gm_snapshot_value leaves every slot alone for a deleted field" {
    // A DELETE delivers value = NULL — the early return keeps the caller's
    // zeroed slots, which is how GML reads "no value".
    var number: f64 = 7;
    var instance: f64 = 7;
    var string = std.mem.zeroes([64]u8);

    c.gm_snapshot_value(c.COLYSEUS_FIELD_REF, null, &number, &string, string.len, &instance);
    c.gm_snapshot_value(c.COLYSEUS_FIELD_STRING, null, &number, &string, string.len, &instance);

    try testing.expectEqual(@as(f64, 7), number);
    try testing.expectEqual(@as(f64, 7), instance);
}

test "gm_snapshot_value flattens primitives and strings" {
    var number: f64 = 0;
    var instance: f64 = 0;
    var string = std.mem.zeroes([64]u8);

    var f: f32 = 1.5;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_FLOAT32, &f, &number, &string, string.len, &instance);
    try testing.expectEqual(@as(f64, 1.5), number);

    var i: i16 = -300;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_INT16, &i, &number, &string, string.len, &instance);
    try testing.expectEqual(@as(f64, -300), number);

    var b: bool = true;
    c.gm_snapshot_value(c.COLYSEUS_FIELD_BOOLEAN, &b, &number, &string, string.len, &instance);
    try testing.expectEqual(@as(f64, 1), number);

    var text = [_]u8{ 'h', 'i', 0 };
    c.gm_snapshot_value(c.COLYSEUS_FIELD_STRING, &text, &number, &string, string.len, &instance);
    try testing.expectEqualStrings("hi", std.mem.sliceTo(&string, 0));

    // ref stays untouched by the branches above
    try testing.expectEqual(@as(f64, 0), instance);
}

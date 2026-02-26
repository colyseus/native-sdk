const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("colyseus/auth/secure_storage.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
});

test "storage: set and get" {
    const result = c.secure_storage_set("test_key", "test_value");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key");
    try testing.expect(value != null);
    try testing.expectEqualStrings("test_value", std.mem.span(value));
    std.c.free(value);
}

test "storage: update" {
    const result = c.secure_storage_set("test_key", "updated_value");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key");
    try testing.expect(value != null);
    try testing.expectEqualStrings("updated_value", std.mem.span(value));
    std.c.free(value);
}

test "storage: remove" {
    const result = c.secure_storage_remove("test_key");
    try testing.expectEqual(@as(c_int, c.STORAGE_OK), result);

    const value = c.secure_storage_get("test_key");
    try testing.expect(value == null);
}

test "storage: non-existent key" {
    const value = c.secure_storage_get("non_existent_key");
    try testing.expect(value == null);
}

test "storage: availability check" {
    const available = c.secure_storage_available();
    // Just verify it returns something reasonable (0 or 1)
    try testing.expect(available == 0 or available == 1);
}

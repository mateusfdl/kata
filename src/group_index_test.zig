const std = @import("std");

const group_index = @import("group_index.zig");

const StringContext = struct {
    pub fn hash(_: StringContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StringContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};
const StringGroups = group_index.Type([]const u8, u16, StringContext);

test "group index keeps first key and value input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const index = try StringGroups.build(arena.allocator(), &.{
        .{ .key = "beta", .value = 2 },
        .{ .key = "alpha", .value = 1 },
        .{ .key = "beta", .value = 4 },
        .{ .key = "alpha", .value = 3 },
    }, .{});

    try std.testing.expectEqual(@as(usize, 2), index.groupCount());
    try std.testing.expectEqualStrings("beta", index.keys[0]);
    try std.testing.expectEqualStrings("alpha", index.keys[1]);
    try std.testing.expectEqualSlices(u16, &.{ 2, 4 }, index.get("beta"));
    try std.testing.expectEqualSlices(u16, &.{ 1, 3 }, index.get("alpha"));
}

test "group index compares the full exact key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const index = try StringGroups.build(arena.allocator(), &.{
        .{ .key = "rule", .value = 1 },
        .{ .key = "rule-extra", .value = 2 },
    }, .{});

    try std.testing.expectEqualSlices(u16, &.{1}, index.get("rule"));
    try std.testing.expectEqualSlices(u16, &.{2}, index.get("rule-extra"));
    try std.testing.expectEqualSlices(u16, &.{}, index.get("missing"));
}

const std = @import("std");

const group_cap = @import("group_cap.zig");

const Item = struct {
    group: []const u8,
    value: u16,
    overflow: bool = false,
};

const StringContext = struct {
    pub fn hash(_: StringContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StringContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

const Callbacks = struct {
    pub fn key(_: Callbacks, item: Item) []const u8 {
        return item.group;
    }

    pub fn cap(_: Callbacks, _: []const u8) usize {
        return 2;
    }

    pub fn overflow(
        _: Callbacks,
        _: std.mem.Allocator,
        first: Item,
        total: usize,
        shown: usize,
    ) !Item {
        return .{
            .group = first.group,
            .value = @intCast(total * 10 + shown),
            .overflow = true,
        };
    }
};

const Cap = group_cap.Type(Item, []const u8, StringContext, Callbacks);

test "group cap keeps interleaved groups in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = try Cap.apply(arena.allocator(), &.{
        .{ .group = "alpha", .value = 1 },
        .{ .group = "beta", .value = 2 },
        .{ .group = "alpha", .value = 3 },
        .{ .group = "beta", .value = 4 },
        .{ .group = "alpha", .value = 5 },
        .{ .group = "alpha", .value = 6 },
    }, .{}, .{}, 2);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 42, 4 }, &.{
        out[0].value,
        out[1].value,
        out[2].value,
        out[3].value,
        out[4].value,
    });
    try std.testing.expectEqual(false, out[0].overflow);
    try std.testing.expectEqual(false, out[1].overflow);
    try std.testing.expectEqual(false, out[2].overflow);
    try std.testing.expectEqual(true, out[3].overflow);
    try std.testing.expectEqual(false, out[4].overflow);
}

test "group cap compares complete exact keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = try Cap.apply(arena.allocator(), &.{
        .{ .group = "rule", .value = 1 },
        .{ .group = "rule-extra", .value = 2 },
        .{ .group = "rule", .value = 3 },
        .{ .group = "rule-extra", .value = 4 },
    }, .{}, .{}, 2);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, &.{
        out[0].value,
        out[1].value,
        out[2].value,
        out[3].value,
    });
}

test "group cap rejects a zero overflow display count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidOverflowShown,
        Cap.apply(arena.allocator(), &.{
            .{ .group = "rule", .value = 1 },
            .{ .group = "rule", .value = 2 },
            .{ .group = "rule", .value = 3 },
        }, .{}, .{}, 0),
    );
}

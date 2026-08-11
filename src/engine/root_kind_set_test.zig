const std = @import("std");

const query = @import("query.zig");
const root_kind_set = @import("root_kind_set.zig");

test "root kind set derives and sorts concrete kinds" {
    const pattern: query.Pattern = .{ .kind = .{ .symbols = &.{ 9, 2, 5 } } };

    const kinds = try root_kind_set.derive(std.testing.allocator, &pattern);
    defer std.testing.allocator.free(kinds);

    try std.testing.expectEqualSlices(u16, &.{ 2, 5, 9 }, kinds);
}

test "root kind set flattens alternations and removes duplicates" {
    const pattern: query.Pattern = .{ .kind = .{ .alternation = &.{
        .{ .kind = .{ .symbol = 8 } },
        .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .anonymous = 3 } },
            .{ .kind = .{ .symbols = &.{ 8, 5 } } },
        } } },
    } } };

    const kinds = try root_kind_set.derive(std.testing.allocator, &pattern);
    defer std.testing.allocator.free(kinds);

    try std.testing.expectEqualSlices(u16, &.{ 3, 5, 8 }, kinds);
}

test "root kind set rejects an empty alternation" {
    const pattern: query.Pattern = .{ .kind = .{ .alternation = &.{} } };

    try std.testing.expectError(
        error.EmptyRootKinds,
        root_kind_set.derive(std.testing.allocator, &pattern),
    );
}

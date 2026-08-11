const std = @import("std");

const line_index = @import("line_index.zig");

test "line index: builds starts and maps bytes to points" {
    var index = try line_index.LineIndex.init(std.testing.allocator, "ab\ncdef\nz");
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 8 }, index.line_starts);
    try std.testing.expectEqual(line_index.Point{ .row = 0, .column = 2 }, index.pointAt(2));
    try std.testing.expectEqual(line_index.Point{ .row = 1, .column = 0 }, index.pointAt(3));
    try std.testing.expectEqual(line_index.Point{ .row = 2, .column = 1 }, index.pointAt(9));
}

test "line index: borrowed starts are not freed by deinit" {
    const starts = [_]u32{ 0, 3 };
    var index = line_index.LineIndex.borrow(&starts);

    index.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, &starts);
}

test "line index: byteAt clamps columns to their line end" {
    var index = try line_index.LineIndex.init(std.testing.allocator, "ab\ncdef\nz");
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), index.byteAt(9, .{ .line = 0, .column = 99 }));
    try std.testing.expectEqual(@as(usize, 7), index.byteAt(9, .{ .line = 1, .column = 99 }));
    try std.testing.expectEqual(@as(usize, 9), index.byteAt(9, .{ .line = 2, .column = 99 }));
    try std.testing.expectEqual(@as(usize, 9), index.byteAt(9, .{ .line = 99, .column = 0 }));
}

test "line index: byteRange normalizes an invalid range at its clamped start" {
    var index = try line_index.LineIndex.init(std.testing.allocator, "ab\ncdef\nz");
    defer index.deinit(std.testing.allocator);

    const range: line_index.Range = .{
        .start = .{ .line = 1, .column = 3 },
        .end = .{ .line = 0, .column = 1 },
    };

    try std.testing.expectEqual(line_index.ByteRange{ .start = 6, .end = 6 }, index.byteRange(9, range));
}

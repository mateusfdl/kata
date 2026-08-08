const std = @import("std");

const sorted_slice = @import("sorted_slice.zig");

const U16Slice = sorted_slice.Type(u16, lessThan);

fn lessThan(a: u16, b: u16) bool {
    return a < b;
}

test "upperBound returns the index after equal values" {
    const values = [_]u16{ 2, 4, 4, 7 };

    try std.testing.expectEqual(@as(usize, 0), U16Slice.upperBound(&values, 1));
    try std.testing.expectEqual(@as(usize, 3), U16Slice.upperBound(&values, 4));
    try std.testing.expectEqual(@as(usize, 4), U16Slice.upperBound(&values, 9));
}

test "contains searches a sorted slice" {
    const values = [_]u16{ 2, 4, 7 };

    try std.testing.expectEqual(true, U16Slice.contains(&values, 4));
    try std.testing.expectEqual(false, U16Slice.contains(&values, 5));
    try std.testing.expectEqual(false, U16Slice.contains(&.{}, 5));
}

test "sortUnique sorts in place and removes equivalent values" {
    var values = [_]u16{ 7, 2, 4, 2, 7, 3 };

    const unique = U16Slice.sortUnique(&values);
    try std.testing.expectEqualSlices(u16, &.{ 2, 3, 4, 7 }, unique);
}

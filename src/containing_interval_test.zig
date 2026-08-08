const std = @import("std");

const containing_interval = @import("containing_interval.zig");
const interval = @import("interval.zig");

const Range = interval.Type(u32, .half_open);
const Item = struct {
    name: []const u8,
    range: Range,
};
const ItemSelector = containing_interval.Selector(Item, Range, itemRange);

fn itemRange(item: Item) Range {
    return item.range;
}

test "innermost selects the nearest strict container" {
    const items = [_]Item{
        .{ .name = "outer", .range = Range.init(0, 20) },
        .{ .name = "inner", .range = Range.init(4, 12) },
        .{ .name = "same", .range = Range.init(6, 8) },
    };

    const index = ItemSelector.innermost(&items, Range.init(6, 8)).?;
    try std.testing.expectEqualStrings("inner", items[index].name);
}

test "innermost returns no item for a root interval" {
    const items = [_]Item{
        .{ .name = "same", .range = Range.init(0, 10) },
        .{ .name = "child", .range = Range.init(2, 4) },
    };

    try std.testing.expectEqual(null, ItemSelector.innermost(&items, Range.init(0, 10)));
}

test "sorted sweep assigns the nearest strict container" {
    const items = [_]Item{
        .{ .name = "root", .range = Range.init(0, 20) },
        .{ .name = "left", .range = Range.init(2, 8) },
        .{ .name = "leaf", .range = Range.init(3, 4) },
        .{ .name = "right", .range = Range.init(10, 15) },
    };

    const owners = try ItemSelector.sweepInnermost(std.testing.allocator, &items);
    defer std.testing.allocator.free(owners);

    try std.testing.expectEqualSlices(?usize, &.{ null, 0, 1, 0 }, owners);
}

test "sorted sweep accepts no items" {
    const owners = try ItemSelector.sweepInnermost(std.testing.allocator, &.{});
    defer std.testing.allocator.free(owners);

    try std.testing.expectEqualSlices(?usize, &.{}, owners);
}

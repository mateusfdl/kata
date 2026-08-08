const std = @import("std");

const dense_multi_map = @import("dense_multi_map.zig");
const TableMemory = @import("table_memory.zig").TableMemory;

const DenseMultiMap = dense_multi_map.DenseMultiMapType(usize);

test "DenseMultiMap empty has no keys or values" {
    const map: DenseMultiMap = .empty;

    try std.testing.expectEqual(@as(usize, 0), map.keyCount());
    try std.testing.expectEqualSlices(usize, &.{}, map.get(0));
}

test "DenseMultiMap stores each key values in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var memory = TableMemory.init(arena.allocator(), std.testing.allocator);
    defer memory.deinit();

    const map = try DenseMultiMap.build(
        &memory,
        4,
        &.{
            .{ .key = 2, .value = 8 },
            .{ .key = 1, .value = 3 },
            .{ .key = 2, .value = 5 },
        },
    );

    try std.testing.expectEqual(@as(usize, 4), map.keyCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 3, 3 }, map.offsets);
    try std.testing.expectEqualSlices(usize, &.{ 3, 8, 5 }, map.values);
    try std.testing.expectEqualSlices(usize, &.{}, map.get(0));
    try std.testing.expectEqualSlices(usize, &.{3}, map.get(1));
    try std.testing.expectEqualSlices(usize, &.{ 8, 5 }, map.get(2));
    try std.testing.expectEqualSlices(usize, &.{}, map.get(4));
}

test "DenseMultiMap rejects a key outside the dense range" {
    var memory = TableMemory.init(std.testing.allocator, std.testing.allocator);
    defer memory.deinit();

    try std.testing.expectError(
        error.KeyOutOfRange,
        DenseMultiMap.build(
            &memory,
            2,
            &.{.{ .key = 2, .value = 9 }},
        ),
    );
}

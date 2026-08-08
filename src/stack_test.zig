const std = @import("std");

const stack = @import("stack.zig");

test "intrusive stack keeps LIFO order and stable node addresses" {
    const Item = struct {
        value: u32,
        link: stack.StackType(@This()).Link = .{},
    };
    const Stack = stack.StackType(Item);

    var items = [_]Item{
        .{ .value = 10 },
        .{ .value = 20 },
        .{ .value = 30 },
    };
    const addresses = [_]*Item{ &items[0], &items[1], &items[2] };
    var values = Stack.init(items.len);

    values.push(&items[0]);
    values.push(&items[1]);
    values.push(&items[2]);

    try std.testing.expectEqual(@as(usize, 3), values.count());
    try std.testing.expectEqual(@as(usize, 3), values.capacity());
    try std.testing.expectEqual(addresses[2], values.peek());
    try std.testing.expectEqual(addresses[2], values.pop());
    try std.testing.expectEqual(addresses[1], values.pop());
    try std.testing.expectEqual(addresses[0], values.pop());
    try std.testing.expectEqual(@as(?*Item, null), values.popOrNull());
    try std.testing.expectEqual(@as(usize, 0), values.count());
    try std.testing.expect(values.empty());
}

test "value stack owns a bounded work region" {
    const ValueStack = stack.ValueStackType(u32);
    var values = try ValueStack.init(std.testing.allocator, 4);
    defer values.deinit();

    values.push(3);
    values.push(5);
    values.push(8);

    try std.testing.expectEqual(@as(usize, 3), values.count());
    try std.testing.expectEqual(@as(usize, 4), values.capacity());
    try std.testing.expectEqualSlices(u32, &.{ 3, 5, 8 }, values.items());
    try std.testing.expectEqual(@as(u32, 8), values.peek());
    try std.testing.expectEqual(@as(u32, 8), values.pop());
    try std.testing.expectEqual(@as(u32, 5), values.pop());
    try std.testing.expectEqual(@as(?u32, 3), values.popOrNull());
    try std.testing.expectEqual(@as(?u32, null), values.popOrNull());
}

test "value stack reset keeps its allocated capacity" {
    const ValueStack = stack.ValueStackType(usize);
    var values = try ValueStack.init(std.testing.allocator, 8);
    defer values.deinit();

    const storage = values.storagePointer();
    values.push(1);
    values.push(2);
    values.reset();

    try std.testing.expectEqual(@as(usize, 0), values.count());
    try std.testing.expectEqual(@as(usize, 8), values.capacity());
    try std.testing.expectEqual(storage, values.storagePointer());
}

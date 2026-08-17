const std = @import("std");

const TableMemory = @import("table_memory.zig").TableMemory;

test "TableMemory keeps output memory when scratch memory resets" {
    var memory = TableMemory.init(std.testing.allocator, std.testing.allocator);
    defer memory.deinit();

    const output_value = try memory.output().create(u32);
    defer memory.output().destroy(output_value);
    output_value.* = 91;

    const scratch_value = try memory.scratch().create(u32);
    scratch_value.* = 17;

    try std.testing.expectEqual(@as(usize, 0), memory.generation());
    memory.resetScratch();

    try std.testing.expectEqual(@as(usize, 1), memory.generation());
    try std.testing.expectEqual(@as(u32, 91), output_value.*);

    const next_scratch_value = try memory.scratch().create(u32);
    next_scratch_value.* = 23;
    try std.testing.expectEqual(@as(u32, 23), next_scratch_value.*);
}

test "TableMemory can use different output and scratch allocators" {
    var output_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var scratch_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var memory = TableMemory.init(output_backing.allocator(), scratch_backing.allocator());

    const output_allocator = memory.output();
    const output_value = try output_allocator.create(u8);
    _ = try memory.scratch().create(u8);

    try std.testing.expectEqual(@as(usize, 1), output_backing.allocations);
    try std.testing.expect(scratch_backing.allocations > 0);

    memory.resetScratch();
    memory.deinit();
    output_allocator.destroy(output_value);

    try std.testing.expectEqual(output_backing.allocated_bytes, output_backing.freed_bytes);
    try std.testing.expectEqual(scratch_backing.allocated_bytes, scratch_backing.freed_bytes);
}

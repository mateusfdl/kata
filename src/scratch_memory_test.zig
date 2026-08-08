const std = @import("std");

const ScratchMemory = @import("scratch_memory.zig").ScratchMemory;

test "scratch memory grows without a fixed capacity" {
    var scratch = ScratchMemory.init(std.testing.allocator);
    defer scratch.deinit();

    const small = try scratch.allocator().alloc(u8, 32);
    const large = try scratch.allocator().alloc(u8, 2 * 1024 * 1024);
    @memset(small, 0xa5);
    @memset(large, 0x5a);

    try std.testing.expect(scratch.capacity() >= small.len + large.len);
    try std.testing.expectEqual(@as(u8, 0xa5), small[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), large[large.len - 1]);
}

test "scratch reset advances generation and retains reusable capacity" {
    var scratch = ScratchMemory.init(std.testing.allocator);
    defer scratch.deinit();

    const first = try scratch.allocator().alloc(u64, 1_024);
    @memset(first, 42);
    const old_generation = scratch.generation();
    const old_capacity = scratch.capacity();

    scratch.reset();

    try std.testing.expectEqual(old_generation + 1, scratch.generation());
    try std.testing.expectEqual(old_capacity, scratch.capacity());
    const second = try scratch.allocator().alloc(u64, 1_024);
    @memset(second, 17);
    try std.testing.expectEqual(@as(u64, 17), second[1_023]);
}

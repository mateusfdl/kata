const std = @import("std");

const ReusableArena = @import("reusable_arena.zig").ReusableArena;

test "reusable arena grows without a fixed capacity" {
    var arena = ReusableArena.init(std.testing.allocator);
    defer arena.deinit();

    const small = try arena.allocator().alloc(u8, 32);
    const large = try arena.allocator().alloc(u8, 2 * 1024 * 1024);
    @memset(small, 0xa5);
    @memset(large, 0x5a);

    try std.testing.expect(arena.capacity() >= small.len + large.len);
    try std.testing.expectEqual(@as(u8, 0xa5), small[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), large[large.len - 1]);
}

test "arena reset advances generation and retains reusable capacity" {
    var arena = ReusableArena.init(std.testing.allocator);
    defer arena.deinit();

    const first = try arena.allocator().alloc(u64, 1_024);
    @memset(first, 42);
    const old_generation = arena.generation();
    const old_capacity = arena.capacity();

    arena.reset();

    try std.testing.expectEqual(old_generation + 1, arena.generation());
    try std.testing.expectEqual(old_capacity, arena.capacity());
    const second = try arena.allocator().alloc(u64, 1_024);
    @memset(second, 17);
    try std.testing.expectEqual(@as(u64, 17), second[1_023]);
}

const std = @import("std");

const OwnedArena = @import("owned_arena.zig").OwnedArena;

test "OwnedArena allocates its handle and arena from one backing allocator" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});

    const arena = try OwnedArena.create(backing.allocator());
    const first = try arena.allocator().create(u64);
    const bytes = try arena.allocator().alloc(u8, 4096);
    first.* = 42;
    @memset(bytes, 7);
    arena.makeStatic();

    try std.testing.expectEqual(@as(u64, 42), first.*);
    try std.testing.expectEqual(@as(u8, 7), bytes[4095]);
    try std.testing.expectEqual(
        @import("static_allocator.zig").StaticAllocator.State.static,
        arena.static_allocator.state,
    );

    arena.deinit();

    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    try std.testing.expectEqual(backing.allocations, backing.deallocations);
}

test "OwnedArena reports handle allocation failure" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(error.OutOfMemory, OwnedArena.create(backing.allocator()));
    try std.testing.expectEqual(@as(usize, 0), backing.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), backing.freed_bytes);
}

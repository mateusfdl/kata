const std = @import("std");

const StaticAllocator = @import("static_allocator.zig").StaticAllocator;

test "static allocator supports the init static deinit lifecycle" {
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    const allocator = static_allocator.allocator();
    const memory = try allocator.alloc(u64, 16);

    try std.testing.expectEqual(StaticAllocator.State.init, static_allocator.state);
    static_allocator.transition_from_init_to_static();
    try std.testing.expectEqual(StaticAllocator.State.static, static_allocator.state);
    static_allocator.transition_from_static_to_deinit();
    try std.testing.expectEqual(StaticAllocator.State.deinit, static_allocator.state);
    allocator.free(memory);
    try std.testing.expectEqual(StaticAllocator.State.deinit, static_allocator.state);
    static_allocator.deinit();
}

test "free during init starts deinit for error cleanup" {
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    const allocator = static_allocator.allocator();
    const memory = try allocator.alloc(u8, 64);

    allocator.free(memory);

    try std.testing.expectEqual(StaticAllocator.State.deinit, static_allocator.state);
    static_allocator.deinit();
}

test "allocation fails after the static transition" {
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    const allocator = static_allocator.allocator();
    static_allocator.transition_from_init_to_static();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));

    static_allocator.transition_from_static_to_deinit();
    static_allocator.deinit();
}

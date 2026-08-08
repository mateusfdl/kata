const std = @import("std");

pub const ScratchMemory = struct {
    arena: std.heap.ArenaAllocator,
    generation_value: u64 = 0,

    const Self = @This();

    pub fn init(child_allocator: std.mem.Allocator) Self {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *Self) void {
        std.debug.assert(self.generation_value != std.math.maxInt(u64));
        _ = self.arena.reset(.retain_capacity);
        self.generation_value += 1;
    }

    pub fn generation(self: *const Self) u64 {
        return self.generation_value;
    }

    pub fn capacity(self: *const Self) usize {
        return self.arena.queryCapacity();
    }
};

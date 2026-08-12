const std = @import("std");

pub const TableMemory = struct {
    output_allocator: std.mem.Allocator,
    scratch_arena: std.heap.ArenaAllocator,
    scratch_generation: usize = 0,
    live: bool = true,

    const Self = @This();

    pub fn init(output_allocator: std.mem.Allocator, scratch_backing_allocator: std.mem.Allocator) Self {
        return .{
            .output_allocator = output_allocator,
            .scratch_arena = .init(scratch_backing_allocator),
        };
    }

    pub fn output(self: *Self) std.mem.Allocator {
        std.debug.assert(self.live);

        return self.output_allocator;
    }

    pub fn scratch(self: *Self) std.mem.Allocator {
        std.debug.assert(self.live);

        return self.scratch_arena.allocator();
    }

    pub fn generation(self: *const Self) usize {
        std.debug.assert(self.live);
        return self.scratch_generation;
    }

    pub fn resetScratch(self: *Self) void {
        std.debug.assert(self.live);
        _ = self.scratch_arena.reset(.retain_capacity);

        self.scratch_generation = std.math.add(usize, self.scratch_generation, 1) catch @panic("scratch generation overflow");
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.live);
        self.scratch_arena.deinit();
        self.live = false;
    }
};

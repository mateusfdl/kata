const std = @import("std");

const StaticAllocator = @import("static_allocator.zig").StaticAllocator;

pub const OwnedArena = struct {
    backing_allocator: std.mem.Allocator,
    static_allocator: StaticAllocator,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn create(backing_allocator: std.mem.Allocator) std.mem.Allocator.Error!*Self {
        const self = try backing_allocator.create(Self);
        self.backing_allocator = backing_allocator;
        self.static_allocator = .init(backing_allocator);
        self.arena = .init(self.static_allocator.allocator());
        return self;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn makeStatic(self: *Self) void {
        self.static_allocator.transition_from_init_to_static();
    }

    pub fn deinit(self: *Self) void {
        const backing_allocator = self.backing_allocator;
        if (self.static_allocator.state == .static) {
            self.static_allocator.transition_from_static_to_deinit();
        }
        self.arena.deinit();
        self.static_allocator.deinit();
        backing_allocator.destroy(self);
    }
};

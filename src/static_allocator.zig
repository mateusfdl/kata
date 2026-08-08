const std = @import("std");

pub const StaticAllocator = struct {
    parent_allocator: std.mem.Allocator,
    state: State,

    pub const State = enum {
        init,
        static,
        deinit,
    };

    const Self = @This();

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(parent_allocator: std.mem.Allocator) Self {
        return .{
            .parent_allocator = parent_allocator,
            .state = .init,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.state == .static) @panic("static allocator requires a deinit transition");
        if (self.state != .init and self.state != .deinit) @panic("invalid allocator state");
        self.* = undefined;
    }

    pub fn transition_from_init_to_static(self: *Self) void {
        if (self.state != .init) @panic("invalid allocator state transition");
        // The owner finished construction. Freeze addresses and reject all
        // allocation, resize, remap, and free operations until teardown.
        self.state = .static;
    }

    pub fn transition_from_static_to_deinit(self: *Self) void {
        if (self.state != .static) @panic("invalid allocator state transition");
        self.state = .deinit;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.state != .init) return null;
        return self.parent_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.state != .init) return false;
        return self.parent_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.state != .init) return null;
        return self.parent_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.state == .static) @panic("cannot free static memory");
        if (self.state != .init and self.state != .deinit) @panic("invalid allocator state");
        // A free during construction can come from error cleanup. Treat it as
        // the start of teardown so later allocations cannot reuse stable data.
        self.state = .deinit;
        self.parent_allocator.rawFree(memory, alignment, return_address);
    }
};

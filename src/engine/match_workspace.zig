const std = @import("std");

const Node = @import("node.zig").Node;

pub const MatchWorkspace = struct {
    allocator: std.mem.Allocator,
    bindings: []?Node = &.{},
    active_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MatchWorkspace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MatchWorkspace) void {
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn ensureCapacity(self: *MatchWorkspace, capture_count: usize) std.mem.Allocator.Error!void {
        if (capture_count <= self.bindings.len) return;

        self.bindings = try self.allocator.realloc(self.bindings, capture_count);
    }

    pub fn reset(self: *MatchWorkspace, capture_count: usize) std.mem.Allocator.Error!void {
        try self.ensureCapacity(capture_count);
        self.active_len = capture_count;
        @memset(self.bindings[0..capture_count], null);
    }

    pub fn active(self: *MatchWorkspace) []?Node {
        return self.bindings[0..self.active_len];
    }

    pub fn capacity(self: MatchWorkspace) usize {
        return self.bindings.len;
    }
};

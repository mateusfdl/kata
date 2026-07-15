const std = @import("std");

const facts = @import("facts.zig");

pub const ProjectIndex = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(facts.FileFacts) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProjectIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProjectIndex) void {
        var it = self.files.valueIterator();
        while (it.next()) |file_facts| file_facts.deinit();

        self.files.deinit(self.allocator);
    }

    pub fn put(self: *ProjectIndex, file_facts: facts.FileFacts) !void {
        const gop = try self.files.getOrPut(self.allocator, file_facts.path);

        if (gop.found_existing) {
            // the existing key's bytes live in the old facts' arena, so the
            // key must be swapped to the new path before the old arena dies.
            var old = gop.value_ptr.*;
            gop.key_ptr.* = file_facts.path;
            gop.value_ptr.* = file_facts;

            old.deinit();

            return;
        }

        gop.key_ptr.* = file_facts.path;
        gop.value_ptr.* = file_facts;
    }

    pub fn get(self: *const ProjectIndex, path: []const u8) ?*const facts.FileFacts {
        return self.files.getPtr(path);
    }

    pub fn count(self: *const ProjectIndex) usize {
        return self.files.count();
    }
};

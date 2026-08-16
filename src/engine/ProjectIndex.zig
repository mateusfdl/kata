const std = @import("std");

const facts = @import("facts.zig");
const fact_schema = @import("fact_schema.zig");

pub const ProjectIndex = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(facts.FileFacts) = .empty,
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ProjectIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProjectIndex) void {
        var it = self.files.valueIterator();
        while (it.next()) |file_facts| file_facts.deinit();

        self.files.deinit(self.allocator);
    }

    pub fn put(self: *ProjectIndex, file_facts: facts.FileFacts) !void {
        var owned = file_facts;
        errdefer owned.deinit();
        const gop = try self.files.getOrPut(self.allocator, owned.path);

        if (gop.found_existing) {
            // The existing key borrows the old facts arena. Replace both key
            // and value before destroying that arena, or the map retains a
            // dangling key even though its hash is unchanged.
            var old = gop.value_ptr.*;
            const changed = !fact_schema.fileFactsEql(&old, &owned);
            gop.key_ptr.* = owned.path;
            gop.value_ptr.* = owned;

            old.deinit();
            if (changed) self.generation += 1;

            return;
        }

        gop.key_ptr.* = owned.path;
        gop.value_ptr.* = owned;
        self.generation += 1;
    }

    pub fn get(self: *const ProjectIndex, path: []const u8) ?*const facts.FileFacts {
        return self.files.getPtr(path);
    }

    pub fn fileIterator(self: *const ProjectIndex) std.StringHashMapUnmanaged(facts.FileFacts).ValueIterator {
        return self.files.valueIterator();
    }

    pub fn scan(self: *const ProjectIndex, kind: fact_schema.FactKind, sink: anytype) std.mem.Allocator.Error!fact_schema.VisitControl {
        var it = self.files.valueIterator();
        while (it.next()) |file| {
            if (try fact_schema.visitFacts(file, kind, sink) == .stop) return .stop;
        }

        return .continue_scan;
    }

    pub fn remove(self: *ProjectIndex, path: []const u8) bool {
        // fetchRemove detaches the borrowed key before deinit frees the facts
        // arena that owns both the key bytes and all indexed values.
        var removed = self.files.fetchRemove(path) orelse return false;
        removed.value.deinit();
        self.generation += 1;

        return true;
    }
};

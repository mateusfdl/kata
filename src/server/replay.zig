const std = @import("std");

const diagnostic = @import("engine").diagnostic;

pub const ReplayCache = struct {
    gpa: std.mem.Allocator,
    capacity: usize,
    clock: u64 = 0,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        arena: *std.heap.ArenaAllocator,
        content_hash: [32]u8,
        diagnostics: []const diagnostic.Diagnostic,
        last_used: u64,

        fn deinit(self: Entry, gpa: std.mem.Allocator) void {
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };

    pub fn init(gpa: std.mem.Allocator, capacity: usize) ReplayCache {
        return .{ .gpa = gpa, .capacity = capacity };
    }

    pub fn deinit(self: *ReplayCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit(self.gpa);

        self.entries.deinit(self.gpa);
    }

    pub fn get(self: *ReplayCache, path: []const u8, content_hash: [32]u8) ?[]const diagnostic.Diagnostic {
        const entry = self.entries.getPtr(path) orelse return null;
        if (!std.mem.eql(u8, &entry.content_hash, &content_hash)) return null;

        self.clock += 1;
        entry.last_used = self.clock;

        return entry.diagnostics;
    }

    pub fn put(
        self: *ReplayCache,
        path: []const u8,
        content_hash: [32]u8,
        diagnostics: []const diagnostic.Diagnostic,
    ) !void {
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        const owned_path = try arena.dupe(u8, path);
        self.clock += 1;
        const entry: Entry = .{
            .arena = arena_ptr,
            .content_hash = content_hash,
            .diagnostics = try dupeDiagnostics(arena, diagnostics),
            .last_used = self.clock,
        };

        if (self.entries.getPtr(path)) |existing| {
            const old = existing.*;
            const key_ptr = self.entries.getKeyPtr(path).?;
            key_ptr.* = owned_path;
            existing.* = entry;
            old.deinit(self.gpa);

            return;
        }

        if (self.entries.count() >= self.capacity) self.evictOldest();

        try self.entries.put(self.gpa, owned_path, entry);
    }

    fn evictOldest(self: *ReplayCache) void {
        var oldest_path: ?[]const u8 = null;
        var oldest_used: u64 = std.math.maxInt(u64);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_used < oldest_used) {
                oldest_used = kv.value_ptr.last_used;
                oldest_path = kv.key_ptr.*;
            }
        }

        const path = oldest_path orelse return;
        const removed = self.entries.fetchRemove(path).?;
        removed.value.deinit(self.gpa);
    }
};

fn dupeDiagnostics(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const diagnostic.Diagnostic {
    const out = try arena.alloc(diagnostic.Diagnostic, diagnostics.len);
    for (diagnostics, out) |d, *copy| {
        copy.* = .{
            .rule_id = try arena.dupe(u8, d.rule_id),
            .language = try arena.dupe(u8, d.language),
            .message = try arena.dupe(u8, d.message),
            .range = d.range,
            .severity = d.severity,
            .demoted = d.demoted,
            .maturity = d.maturity,
            .fingerprint = try arena.dupe(u8, d.fingerprint),
            .context = try dupeContext(arena, d.context),
            .fix = try dupeFix(arena, d.fix),
            .suggestions = try dupeSuggestions(arena, d.suggestions),
        };
    }

    return out;
}

fn dupeContext(arena: std.mem.Allocator, context: []const diagnostic.Context) ![]const diagnostic.Context {
    const out = try arena.alloc(diagnostic.Context, context.len);
    for (context, out) |entry, *copy| {
        copy.* = .{
            .kind = entry.kind,
            .name = try arena.dupe(u8, entry.name),
            .range = entry.range,
        };
    }

    return out;
}

fn dupeFix(arena: std.mem.Allocator, fix: ?diagnostic.Fix) !?diagnostic.Fix {
    const value = fix orelse return null;

    return .{
        .range = value.range,
        .replacement = try arena.dupe(u8, value.replacement),
        .safety = value.safety,
    };
}

fn dupeSuggestions(arena: std.mem.Allocator, suggestions: []const diagnostic.Suggestion) ![]const diagnostic.Suggestion {
    const out = try arena.alloc(diagnostic.Suggestion, suggestions.len);
    for (suggestions, out) |entry, *copy| {
        copy.* = .{
            .label = try arena.dupe(u8, entry.label),
            .range = entry.range,
            .replacement = try arena.dupe(u8, entry.replacement),
        };
    }

    return out;
}

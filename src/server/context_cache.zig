const std = @import("std");

const fs = @import("../fs.zig");
const sources = @import("../sources.zig");
const replay = @import("replay.zig");

const context = sources.context;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    resolver: *context.Resolver,
    entries: std.StringHashMapUnmanaged(*Entry),

    pub const Entry = struct {
        ctx: *context.Context,
        replay: replay.ReplayCache,
        fingerprint: u64,
    };

    pub fn init(gpa: std.mem.Allocator, resolver: *context.Resolver) Cache {
        return .{ .gpa = gpa, .resolver = resolver, .entries = .empty };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();

        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.destroyEntry(kv.value_ptr.*);
        }

        self.entries.deinit(self.gpa);
    }

    pub fn acquire(self: *Cache, scratch: std.mem.Allocator, anchor: ?[]const u8) !?*Entry {
        const a = anchor orelse return null;
        const root = (try fs.discover.findProjectRoot(self.resolver.io, scratch, a)) orelse return null;
        const current = try projectFingerprint(self.resolver.io, scratch, root);

        if (self.entries.get(root)) |entry| {
            if (entry.fingerprint == current) return entry;

            var fresh_replay = try replay.ReplayCache.init(self.gpa, replay.default_capacity);
            const fresh_ctx = self.resolver.resolveAtRoot(root) catch |err| {
                fresh_replay.deinit();
                const removed = self.entries.fetchRemove(root).?;
                self.gpa.free(removed.key);
                self.destroyEntry(removed.value);

                return err;
            };

            entry.ctx.deinit();
            entry.replay.deinit();
            entry.* = .{ .ctx = fresh_ctx, .replay = fresh_replay, .fingerprint = current };

            return entry;
        }

        const entry = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(entry);
        var fresh_replay = try replay.ReplayCache.init(self.gpa, replay.default_capacity);
        errdefer fresh_replay.deinit();
        const ctx = try self.resolver.resolveAtRoot(root);
        errdefer ctx.deinit();
        const key = try self.gpa.dupe(u8, root);
        errdefer self.gpa.free(key);

        entry.* = .{ .ctx = ctx, .replay = fresh_replay, .fingerprint = current };
        try self.entries.put(self.gpa, key, entry);

        return entry;
    }

    fn destroyEntry(self: *Cache, entry: *Entry) void {
        entry.ctx.deinit();
        entry.replay.deinit();
        self.gpa.destroy(entry);
    }
};

fn projectFingerprint(io: std.Io, scratch: std.mem.Allocator, root: []const u8) !u64 {
    var acc: u64 = 0;
    const kata_dir = try fs.path.join(scratch, root, fs.discover.project_dir_name);

    const yaml_path = try fs.config.rulesPath(scratch, kata_dir);
    if (statOptional(io, yaml_path)) |st| acc ^= entryHash("", "rules.yaml", st);

    const rules_path = try fs.path.join(scratch, kata_dir, context.rules_dir_name);
    var rules_dir = std.Io.Dir.cwd().openDir(io, rules_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return acc,
        else => return err,
    };
    defer rules_dir.close(io);

    var dirs = rules_dir.iterate();
    while (try dirs.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var lang_dir = try rules_dir.openDir(io, entry.name, .{ .iterate = true });
        defer lang_dir.close(io);

        var files = lang_dir.iterate();
        while (try files.next(io)) |fentry| {
            if (fentry.kind != .file) continue;
            if (fs.rules.ruleId(fentry.name) == null) continue;

            const st = try lang_dir.statFile(io, fentry.name, .{});

            acc ^= entryHash(entry.name, fentry.name, st);
        }
    }

    return acc;
}

fn statOptional(io: std.Io, path: []const u8) ?std.Io.File.Stat {
    return fs.file.stat(io, path) catch return null;
}

fn entryHash(dir_name: []const u8, file_name: []const u8, st: std.Io.File.Stat) u64 {
    var hasher = std.hash.Wyhash.init(0);

    hasher.update(dir_name);
    hasher.update("/");
    hasher.update(file_name);
    hasher.update(std.mem.asBytes(&st.size));

    const mtime = st.mtime.toMilliseconds();

    hasher.update(std.mem.asBytes(&mtime));

    return hasher.final();
}

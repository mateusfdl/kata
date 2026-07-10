const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("../lint.zig");
const config = @import("config.zig");
const dsl = @import("dsl");
const loader = @import("loader.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const rules_dir_name = "rules";

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_ptr: *std.heap.ArenaAllocator,
    root: ?[]const u8,
    project_config: ?config.Config,
    resolved: config.Resolved,
    rule_set: loader.RuleSet,
    engine: Engine,

    pub fn deinit(self: *Context) void {
        self.engine.deinit();
        self.rule_set.deinit();

        if (self.project_config) |*c| c.deinit();

        const child = self.arena_ptr.child_allocator;
        self.arena_ptr.deinit();

        child.destroy(self.arena_ptr);
        self.gpa.destroy(self);
    }
};

pub const Resolver = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    user_rules_dir: ?[]const u8 = null,
    global_config: ?*const config.Config = null,
    diag: config.Diagnostic = .{},

    pub fn resolve(self: *Resolver, anchor: ?[]const u8) !*Context {
        const ctx = try self.gpa.create(Context);
        errdefer self.gpa.destroy(ctx);
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(arena_ptr);
        arena_ptr.* = .init(self.gpa);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();
        const root = try self.discoverRoot(arena, anchor);

        return self.build(ctx, arena_ptr, root);
    }

    fn discoverRoot(self: *Resolver, arena: std.mem.Allocator, anchor: ?[]const u8) !?[]const u8 {
        const a = anchor orelse return null;

        return try fs.discover.findProjectRoot(self.io, arena, a);
    }

    pub fn resolveAtRoot(self: *Resolver, root: []const u8) !*Context {
        const ctx = try self.gpa.create(Context);
        errdefer self.gpa.destroy(ctx);
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(arena_ptr);
        arena_ptr.* = .init(self.gpa);
        errdefer arena_ptr.deinit();

        return self.build(ctx, arena_ptr, try arena_ptr.allocator().dupe(u8, root));
    }

    fn build(self: *Resolver, ctx: *Context, arena_ptr: *std.heap.ArenaAllocator, root: ?[]const u8) !*Context {
        const arena = arena_ptr.allocator();

        var project_config: ?config.Config = null;
        errdefer if (project_config) |*c| c.deinit();
        var project_rules_dir: ?[]const u8 = null;

        if (root) |r| {
            const kata_dir = try fs.path.join(arena, r, fs.discover.project_dir_name);
            const rules_dir = try fs.path.join(arena, kata_dir, rules_dir_name);
            if (try fs.discover.isDirectory(self.io, rules_dir)) project_rules_dir = rules_dir;
            const yaml_path = try fs.config.rulesPath(arena, kata_dir);
            if (try fs.config.readRulesYaml(self.io, arena, yaml_path)) |source| {
                self.diag = .{};
                project_config = try config.parse(self.gpa, source, &self.diag);
            }
        }

        var rule_set = try loader.load(arena, self.io, .{
            .user_dir = self.user_rules_dir,
            .project_dir = project_rules_dir,
        });
        errdefer rule_set.deinit();

        const resolved = config.resolve(self.global_config, if (project_config) |*c| c else null);
        config.applySelection(&rule_set, resolved);

        ctx.* = .{
            .gpa = self.gpa,
            .arena_ptr = arena_ptr,
            .root = root,
            .project_config = project_config,
            .resolved = resolved,
            .rule_set = rule_set,
            .engine = undefined,
        };
        ctx.engine = Engine.init(self.gpa, &ctx.rule_set, dsl.engine_compiler.ruleCompiler());
        ctx.engine.metrics = resolved.metrics;
        ctx.engine.warnings = resolved.warnings;

        return ctx;
    }
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    resolver: *Resolver,
    entries: std.StringHashMapUnmanaged(Entry),

    const Entry = struct {
        ctx: *Context,
        fingerprint: u64,
    };

    pub fn init(gpa: std.mem.Allocator, resolver: *Resolver) Cache {
        return .{ .gpa = gpa, .resolver = resolver, .entries = .empty };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();

        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.ctx.deinit();
        }

        self.entries.deinit(self.gpa);
    }

    pub fn acquire(self: *Cache, scratch: std.mem.Allocator, anchor: ?[]const u8) !?*Context {
        const a = anchor orelse return null;
        const root = (try fs.discover.findProjectRoot(self.resolver.io, scratch, a)) orelse return null;
        const current = try projectFingerprint(self.resolver.io, scratch, root);

        if (self.entries.getPtr(root)) |entry| {
            if (entry.fingerprint == current) return entry.ctx;

            entry.ctx.deinit();
            entry.ctx = self.resolver.resolveAtRoot(root) catch |err| {
                const removed = self.entries.fetchRemove(root).?;
                self.gpa.free(removed.key);
                return err;
            };

            entry.fingerprint = current;

            return entry.ctx;
        }

        const ctx = try self.resolver.resolveAtRoot(root);
        errdefer ctx.deinit();
        const key = try self.gpa.dupe(u8, root);
        errdefer self.gpa.free(key);

        try self.entries.put(self.gpa, key, .{ .ctx = ctx, .fingerprint = current });

        return ctx;
    }
};

fn projectFingerprint(io: std.Io, scratch: std.mem.Allocator, root: []const u8) !u64 {
    var acc: u64 = 0;
    const kata_dir = try fs.path.join(scratch, root, fs.discover.project_dir_name);

    const yaml_path = try fs.config.rulesPath(scratch, kata_dir);
    if (statOptional(io, yaml_path)) |st| acc ^= entryHash("", "rules.yaml", st);

    const rules_path = try fs.path.join(scratch, kata_dir, rules_dir_name);
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

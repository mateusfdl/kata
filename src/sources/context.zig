const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("../lint.zig");
const config = @import("config.zig");
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
    registry: *language.Registry,
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

        return self.build(ctx, arena_ptr, if (anchor) |a| try fs.discover.findProjectRoot(self.io, arena, a) else null);
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
        config.filterDisabled(&rule_set, resolved);

        ctx.* = .{
            .gpa = self.gpa,
            .arena_ptr = arena_ptr,
            .root = root,
            .project_config = project_config,
            .resolved = resolved,
            .rule_set = rule_set,
            .engine = undefined,
        };
        ctx.engine = Engine.init(self.gpa, self.registry, &ctx.rule_set);
        ctx.engine.metrics = resolved.metrics;
        ctx.engine.warnings = resolved.warnings;
        return ctx;
    }
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    resolver: *Resolver,
    entries: std.StringHashMapUnmanaged(*Context),

    pub fn init(gpa: std.mem.Allocator, resolver: *Resolver) Cache {
        return .{ .gpa = gpa, .resolver = resolver, .entries = .empty };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.entries.deinit(self.gpa);
    }

    pub fn acquire(self: *Cache, scratch: std.mem.Allocator, anchor: ?[]const u8) !?*Context {
        const a = anchor orelse return null;
        const root = (try fs.discover.findProjectRoot(self.resolver.io, scratch, a)) orelse return null;
        if (self.entries.get(root)) |ctx| return ctx;

        const ctx = try self.resolver.resolveAtRoot(root);
        errdefer ctx.deinit();
        const key = try self.gpa.dupe(u8, root);
        errdefer self.gpa.free(key);
        try self.entries.put(self.gpa, key, ctx);
        return ctx;
    }
};

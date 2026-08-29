const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const config = @import("config.zig");
const dsl = @import("dsl");
const lifecycle = @import("lifecycle.zig");
const loader = @import("loader.zig");
const retired = @import("retired.zig");
const rules_hash = @import("rules_hash.zig");

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
    rules_hash: [32]u8,
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
    rule_diag: lint.rule.Diagnostic = .{},
    retired_diag: retired.Diagnostic = .{},

    pub fn resolve(self: *Resolver, anchor: ?[]const u8) !*Context {
        return self.create(.{ .anchor = anchor });
    }

    pub fn resolveAtRoot(self: *Resolver, root: []const u8) !*Context {
        return self.create(.{ .root = root });
    }

    const Target = union(enum) {
        anchor: ?[]const u8,
        root: []const u8,
    };

    fn create(self: *Resolver, target: Target) !*Context {
        const ctx = try self.gpa.create(Context);
        errdefer self.gpa.destroy(ctx);
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(arena_ptr);
        arena_ptr.* = .init(self.gpa);
        errdefer arena_ptr.deinit();

        const arena = arena_ptr.allocator();
        const root = switch (target) {
            .anchor => |a| try self.discoverRoot(arena, a),
            .root => |r| try arena.dupe(u8, r),
        };

        return self.build(ctx, arena_ptr, root);
    }

    fn loadRetired(self: *Resolver, arena: std.mem.Allocator, project_rules_dir: ?[]const u8) !retired.Registry {
        self.retired_diag = .{};
        var registry = try retired.parse(arena, retired.embedded_source, &self.retired_diag);
        if (self.user_rules_dir) |dir| try self.overlayRetired(arena, &registry, dir);
        if (project_rules_dir) |dir| try self.overlayRetired(arena, &registry, dir);

        return registry;
    }

    fn overlayRetired(self: *Resolver, arena: std.mem.Allocator, registry: *retired.Registry, rules_dir: []const u8) !void {
        const source = (try fs.rules.readRetired(self.io, arena, rules_dir)) orelse return;
        const overlay = try retired.parse(arena, source, &self.retired_diag);

        try retired.merge(arena, registry, overlay);
    }

    fn discoverRoot(self: *Resolver, arena: std.mem.Allocator, anchor: ?[]const u8) !?[]const u8 {
        const a = anchor orelse return null;

        return try fs.discover.findProjectRoot(self.io, arena, a);
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

        self.rule_diag = .{};
        var table = try lifecycle.build(arena, &rule_set, &self.rule_diag);
        table.retired = try self.loadRetired(arena, project_rules_dir);

        var resolved = try config.resolve(arena, self.global_config, if (project_config) |*c| c else null);
        try config.applySelection(arena, &rule_set, &resolved, &table, &self.rule_diag);

        ctx.* = .{
            .gpa = self.gpa,
            .arena_ptr = arena_ptr,
            .root = root,
            .project_config = project_config,
            .resolved = resolved,
            .rule_set = rule_set,
            .rules_hash = rules_hash.compute(&rule_set, resolved),
            .engine = undefined,
        };

        ctx.engine = Engine.init(self.gpa, &ctx.rule_set, dsl.engine_compiler.ruleCompiler(), resolved.settings);

        return ctx;
    }
};

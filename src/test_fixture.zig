const std = @import("std");

const dsl = @import("dsl");
const lint = @import("engine");
const sources = @import("sources.zig");

const config = sources.config;
const context = sources.context;
const loader = sources.loader;

const Engine = lint.Engine;
const language = lint.language;

pub const kata_ident =
    \\rule marker {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "flag" }
    \\}
;

pub const kata_local_old =
    \\rule local {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "old" }
    \\}
;

pub const kata_local_new =
    \\rule local {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "new body, strictly longer than the old one" }
    \\}
;

pub const TmpProject = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    pub fn init() !*TmpProject {
        const gpa = std.testing.allocator;
        const self = try gpa.create(TmpProject);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(gpa),
            .root = undefined,
        };
        var rel_buf: [256]u8 = undefined;
        const rel = try relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        self.root = try self.arena.allocator().dupe(u8, rel);
        return self;
    }

    pub fn deinit(self: *TmpProject) void {
        const gpa = std.testing.allocator;
        self.tmp.cleanup();
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn path(self: *TmpProject, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.root, sub });
    }
};

pub fn resolver(user_rules_dir: ?[]const u8, global: ?*const config.Config) context.Resolver {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .user_rules_dir = user_rules_dir,
        .global_config = global,
    };
}

pub fn parseGlobal(yaml: []const u8) !config.Config {
    var diag: config.Diagnostic = .{};
    return try config.parse(std.testing.allocator, yaml, &diag);
}

pub fn ruleSource(set: anytype, lang: language.Name, id: []const u8) ?[]const u8 {
    for (set.get(lang)) |r| {
        if (std.mem.eql(u8, r.id, id)) return r.source;
    }
    return null;
}

pub const no_as_any_rule =
    \\rule no-as-any {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: predefined_type @t
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "as any is not allowed" }
    \\}
    \\rule no-as-any {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: array_type {
    \\      child: predefined_type @t
    \\    }
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "as any[] is not allowed" }
    \\}
;

pub fn relativeTmpPath(buf: []u8, sub_path: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{sub_path});
}

pub fn runGit(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,

        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    rule_set: loader.RuleSet,
    engine: Engine,

    pub fn init(
        allocator: std.mem.Allocator,
        langs: []const language.Name,
        id: []const u8,
        source: []const u8,
    ) !*Fixture {
        return initWithSettings(allocator, langs, id, source, &.{});
    }

    pub fn initWithSettings(
        allocator: std.mem.Allocator,
        langs: []const language.Name,
        id: []const u8,
        source: []const u8,
        settings: []const lint.rule.RuleSetting,
    ) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{
            .allocator = allocator,
            .rule_set = .{ .allocator = allocator },
            .engine = undefined,
        };
        for (langs) |l| try self.add(l, id, source);

        self.engine = Engine.init(allocator, &self.rule_set, dsl.engine_compiler.ruleCompiler(), settings);
        return self;
    }

    pub fn add(
        self: *Fixture,
        lang: language.Name,
        id: []const u8,
        source: []const u8,
    ) !void {
        try self.rule_set.append(lang, .{
            .id = try self.allocator.dupe(u8, id),
            .source = try self.allocator.dupe(u8, source),
        });
    }

    pub fn deinit(self: *Fixture) void {
        self.engine.deinit();
        var it = self.rule_set.by_lang.iterator();
        while (it.next()) |entry| {
            for (entry.value.items) |r| {
                self.allocator.free(r.id);
                self.allocator.free(r.source);
            }
        }
        self.rule_set.deinit();
        self.allocator.destroy(self);
    }
};

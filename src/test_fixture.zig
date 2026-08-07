const std = @import("std");

const dsl = @import("dsl");
const lint = @import("engine");
const loader = @import("sources.zig").loader;

const Engine = lint.Engine;
const language = lint.language;

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

const std = @import("std");

const lint = @import("lint.zig");
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
        return initFormat(allocator, langs, id, source, .kata);
    }

    pub fn initFormat(
        allocator: std.mem.Allocator,
        langs: []const language.Name,
        id: []const u8,
        source: []const u8,
        format: lint.rule.Format,
    ) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{
            .allocator = allocator,
            .rule_set = .{ .allocator = allocator },
            .engine = undefined,
        };
        for (langs) |l| try self.add(l, id, source, format);

        self.engine = Engine.init(allocator, &self.rule_set);
        return self;
    }

    pub fn add(
        self: *Fixture,
        lang: language.Name,
        id: []const u8,
        source: []const u8,
        format: lint.rule.Format,
    ) !void {
        try self.rule_set.append(lang, .{
            .id = try self.allocator.dupe(u8, id),
            .source = try self.allocator.dupe(u8, source),
            .format = format,
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

const std = @import("std");

const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const loader = @import("loader.zig");

pub const no_as_any_rule =
    \\((as_expression (predefined_type) @t) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any is not allowed"))
    \\
    \\((as_expression (array_type (predefined_type) @t)) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any[] is not allowed"))
    \\
;

pub fn relativeTmpPath(buf: []u8, sub_path: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{sub_path});
}

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    registry: language.Registry,
    rule_set: loader.RuleSet,
    engine: engine_mod.Engine,

    pub fn init(
        allocator: std.mem.Allocator,
        langs: []const language.Name,
        id: []const u8,
        source: []const u8,
    ) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{
            .allocator = allocator,
            .registry = .init(),
            .rule_set = .{ .allocator = allocator },
            .engine = undefined,
        };

        for (langs) |l| {
            try self.rule_set.append(l, .{
                .id = try allocator.dupe(u8, id),
                .language = l,
                .source = try allocator.dupe(u8, source),
            });
        }

        self.engine = engine_mod.Engine.init(allocator, &self.registry, &self.rule_set);
        return self;
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
        self.registry.deinit();
        self.allocator.destroy(self);
    }
};

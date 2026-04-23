const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const loader = @import("loader.zig");
const rule = @import("rule.zig");

const no_as_any_rule =
    \\((as_expression (predefined_type) @t) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any is not allowed"))
    \\
    \\((as_expression (array_type (predefined_type) @t)) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any[] is not allowed"))
    \\
;

const Fixture = struct {
    allocator: std.mem.Allocator,
    registry: language.Registry,
    rule_set: loader.RuleSet,
    engine: engine_mod.Engine,

    fn init(allocator: std.mem.Allocator, langs: []const language.Name) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{
            .allocator = allocator,
            .registry = .init(),
            .rule_set = .{ .allocator = allocator },
            .engine = undefined,
        };

        for (langs) |l| {
            try self.rule_set.append(l, .{
                .id = try allocator.dupe(u8, "no-as-any"),
                .language = l,
                .source = try allocator.dupe(u8, no_as_any_rule),
            });
        }

        self.engine = engine_mod.Engine.init(allocator, &self.registry, &self.rule_set);
        return self;
    }

    fn deinit(self: *Fixture) void {
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

test "engine: detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = (foo[0] as any).bar;";
    const diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    const d = diags[0];
    try std.testing.expectEqualStrings("no-as-any", d.rule_id);
    try std.testing.expectEqualStrings("ts", d.language);
    try std.testing.expectEqualStrings("error", d.severity);
    try std.testing.expectEqualStrings("as any is not allowed", d.message);
    try std.testing.expectEqual(@as(u32, 0), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 11), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 0), d.range.end.line);
    try std.testing.expectEqual(@as(u32, 24), d.range.end.column);
}

test "engine: detects `as any[]`" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = foo as any[];";
    const diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("as any[] is not allowed", diags[0].message);
}

test "engine: clean sources produce no diagnostics" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts});
    defer f.deinit();

    const cases = [_][]const u8{
        "const x: string = \"foo\";",
        "const y = foo as string;",
        "const z = foo as unknown as number;",
        "type Handler = (input: string) => number;",
    };

    for (cases) |src| {
        const diags = try f.engine.lint(gpa, src, .ts);
        defer gpa.free(diags);
        if (diags.len != 0) {
            std.debug.print("unexpected diagnostics for {s}:\n", .{src});
            for (diags) |d| std.debug.print("  {s}: {s}\n", .{ d.rule_id, d.message });
        }
        try std.testing.expectEqual(@as(usize, 0), diags.len);
    }
}

test "engine: tsx detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.tsx});
    defer f.deinit();

    const src = "const Comp = () => <div>{(props as any).label}</div>;";
    const diags = try f.engine.lint(gpa, src, .tsx);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("tsx", diags[0].language);
}

test "engine: multiple violations across lines" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts});
    defer f.deinit();

    const src = "const a = x as any;\nconst b = y as any;\n";
    const diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

test "engine: per-language rule filtering" {
    const gpa = std.testing.allocator;
    // Rules only registered for .ts; .tsx bundle empty.
    var f = try Fixture.init(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = foo as any;";
    const diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("ts", diags[0].language);

    const tsx_diags = try f.engine.lint(gpa, src, .tsx);
    defer gpa.free(tsx_diags);
    try std.testing.expectEqual(@as(usize, 0), tsx_diags.len);
}

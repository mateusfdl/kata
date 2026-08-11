const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const dispatch = @import("dispatch.zig");
const Engine = @import("Engine.zig");
const expr = @import("expr.zig");
const family = @import("family/family.zig");
const metric = @import("metric.zig");
const MetricCache = @import("metric_cache.zig").MetricCache;
const OwnedArena = @import("shared").owned_arena.OwnedArena;
const rule = @import("rule.zig");
const test_tree = @import("test_tree.zig");

test "metric cache: one analysis provides complexity and nesting" {
    const gpa = std.testing.allocator;
    const source = "function f(a) { if (a) { for (;;) { a(); } } }";
    var tree = test_tree.build(gpa, .ts, source);
    defer tree.deinit(gpa);
    var compiled = try metric.compile(gpa, tree.lang.family());
    defer compiled.deinit(gpa);
    var cache = try MetricCache.init(gpa, tree.root());
    defer cache.deinit();

    const function = tree.root().namedChild(0).?;
    try std.testing.expectEqual(@as(u32, 3), try cache.complexity(gpa, &compiled, function));
    try std.testing.expectEqual(@as(u32, 2), try cache.nesting(gpa, &compiled, function));
    try std.testing.expectEqual(@as(usize, 1), cache.analysisCount());
}

test "metric cache: two rules reuse one node analysis across scratch resets" {
    const gpa = std.testing.allocator;
    const source = "function f(a) { if (a) { for (;;) { a(); } } }";
    var tree = test_tree.build(gpa, .ts, source);
    defer tree.deinit(gpa);
    var compiled = try metric.compile(gpa, tree.lang.family());
    defer compiled.deinit(gpa);
    var cache = try MetricCache.init(gpa, tree.root());
    defer cache.deinit();

    const complexity: expr.Expr = .{ .compare = .{
        .op = .eq,
        .left = .{ .measure = .{ .measure = .complexity, .capture_id = 0 } },
        .right = .{ .number = 3 },
    } };
    const nesting: expr.Expr = .{ .compare = .{
        .op = .eq,
        .left = .{ .measure = .{ .measure = .nesting, .capture_id = 0 } },
        .right = .{ .number = 2 },
    } };
    var complexity_predicates = [_]rule.Predicate{.{ .where = &complexity }};
    var nesting_predicates = [_]rule.Predicate{.{ .where = &nesting }};
    var patterns = [_]rule.CompiledPattern{
        .{
            .pattern = .{ .kind = .{ .symbol = tree.sym("function_declaration") }, .capture = 0 },
            .capture_count = 1,
            .match_capture_id = 0,
            .meta = .{
                .predicates = &complexity_predicates,
                .message = .{ .plain = "complexity" },
                .rule_id = "complexity-rule",
            },
        },
        .{
            .pattern = .{ .kind = .{ .symbol = tree.sym("function_declaration") }, .capture = 0 },
            .capture_count = 1,
            .match_capture_id = 0,
            .meta = .{
                .predicates = &nesting_predicates,
                .message = .{ .plain = "nesting" },
                .rule_id = "nesting-rule",
            },
        },
    };
    const arena = try OwnedArena.create(gpa);
    var compiled_rule: rule.CompiledRule = .{
        .patterns = &patterns,
        .needs_measures = true,
        .arena = arena,
    };
    defer compiled_rule.deinit();
    compiled_rule.dispatch = try dispatch.Table.build(
        arena.allocator(),
        gpa,
        &patterns,
        family.of(.ts_family).kind_count,
    );
    var diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(gpa);

    try Engine.runRule(gpa, &compiled_rule, .{
        .allocator = gpa,
        .source = source,
        .root = tree.root(),
        .metric = .{
            .allocator = gpa,
            .compiled = &compiled,
            .fam = tree.lang.family(),
            .cache = &cache,
        },
    }, .ts, &.{}, null, &diagnostics);

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), cache.analysisCount());
}

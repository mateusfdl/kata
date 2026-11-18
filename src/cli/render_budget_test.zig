const std = @import("std");

const lint = @import("engine");
const budget = @import("render_budget.zig");
const reports = @import("../reports.zig");

test "render budget: repeated batches count each affected path once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var run: budget.RenderBudget = .{ .gpa = std.testing.allocator };
    defer run.deinit();
    const diagnostic: lint.diagnostic.Diagnostic = .{
        .rule_id = "rule",
        .language = "ts",
        .message = "finding",
        .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 1 } },
    };
    const initial: [budget.per_rule]lint.diagnostic.Diagnostic = @splat(diagnostic);
    try std.testing.expectEqualDeep(&initial, try run.filterFile(arena.allocator(), "a.ts", &initial));
    for ([_][]const u8{ "a.ts", "a.ts", "b.ts", "a.ts" }) |path| {
        try std.testing.expectEqualDeep(@as([]const lint.diagnostic.Diagnostic, &.{}), try run.filterFile(arena.allocator(), path, &.{diagnostic}));
    }
    try std.testing.expectEqualDeep(
        @as([]const reports.RuleOverflow, &.{.{ .rule_id = "rule", .suppressed = 4, .files = 2 }}),
        try run.overflow(arena.allocator()),
    );
}

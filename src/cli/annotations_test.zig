const std = @import("std");

const annotations = @import("annotations.zig");
const lint = @import("engine");

test "annotations: comparison is repeatable and consumes duplicate expectations once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expected = try annotations.Annotations.parse(arena.allocator(), "// kata-expect: first, first\n// kata-expect-fix: expected\nx\n");
    const range: lint.diagnostic.Range = .{ .start = .{ .line = 2, .column = 0 }, .end = .{ .line = 2, .column = 1 } };
    const diagnostics = [_]lint.diagnostic.Diagnostic{.{
        .rule_id = "first",
        .language = "ts",
        .message = "finding",
        .range = range,
        .fix = .{ .range = range, .replacement = "actual", .safety = .safe },
    }};
    const first = try expected.compare(arena.allocator(), &diagnostics);
    const second = try expected.compare(arena.allocator(), &diagnostics);
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqualDeep(@as([]const annotations.Problem, &.{
        .{ .line = 2, .message = "missing [first]" },
        .{ .line = 2, .message = "wrong fix \"actual\" (expected \"expected\")" },
    }), first.problems);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"first"}), first.rules_with_asserted_fix);
}

const std = @import("std");

const lint = @import("engine");
const edits = lint.edits;

test "edits: fromFixes converts line and column ranges to byte offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "a\nconst n = parseInt(x);\n";
    const fixes = [_]lint.diagnostic.Fix{.{
        .range = .{ .start = .{ .line = 1, .column = 10 }, .end = .{ .line = 1, .column = 18 } },
        .replacement = "Number.parseInt",
        .safety = .safe,
    }};
    const list = try edits.fromFixes(arena.allocator(), source, &fixes);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(usize, 12), list[0].start);
    try std.testing.expectEqual(@as(usize, 20), list[0].end);
    try std.testing.expectEqualStrings("Number.parseInt", list[0].text);
}

test "edits: fromFixes clamps columns at the selected line end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fixes = [_]lint.diagnostic.Fix{.{
        .range = .{ .start = .{ .line = 0, .column = 1 }, .end = .{ .line = 0, .column = 99 } },
        .replacement = "x",
        .safety = .safe,
    }};
    const list = try edits.fromFixes(arena.allocator(), "ab\ncdef\n", &fixes);

    try std.testing.expectEqual(@as(usize, 1), list[0].start);
    try std.testing.expectEqual(@as(usize, 2), list[0].end);
}

const std = @import("std");

const lint = @import("engine");
const edits = lint.edits;

test "edits: applies a single replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "const n = parseInt(x);\n";
    var list = [_]edits.Edit{.{ .start = 10, .end = 18, .text = "Number.parseInt" }};
    const result = try edits.apply(arena.allocator(), source, &list);

    try std.testing.expectEqualStrings("const n = Number.parseInt(x);\n", result.source);
}

test "edits: an empty text deletes the span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var list = [_]edits.Edit{.{ .start = 5, .end = 11, .text = "" }};
    const result = try edits.apply(arena.allocator(), "keep DELETE keep\n", &list);

    try std.testing.expectEqualStrings("keep  keep\n", result.source);
}

test "edits: applies unsorted edits in position order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var list = [_]edits.Edit{
        .{ .start = 8, .end = 9, .text = "two" },
        .{ .start = 0, .end = 3, .text = "one" },
    };
    const result = try edits.apply(arena.allocator(), "aaa bbb c ddd\n", &list);

    try std.testing.expectEqualStrings("one bbb two ddd\n", result.source);
}

test "edits: skips an edit overlapping an applied one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var list = [_]edits.Edit{
        .{ .start = 0, .end = 8, .text = "first" },
        .{ .start = 4, .end = 12, .text = "second" },
    };
    const result = try edits.apply(arena.allocator(), "aaaabbbbcccc\n", &list);

    try std.testing.expectEqualStrings("firstcccc\n", result.source);
}

test "edits: skips a duplicate of an applied range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var list = [_]edits.Edit{
        .{ .start = 0, .end = 4, .text = "kept" },
        .{ .start = 0, .end = 4, .text = "lost" },
    };
    const result = try edits.apply(arena.allocator(), "aaaa rest\n", &list);

    try std.testing.expectEqualStrings("kept rest\n", result.source);
}

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

    const result = try edits.apply(arena.allocator(), source, list);
    try std.testing.expectEqualStrings("a\nconst n = Number.parseInt(x);\n", result.source);
}

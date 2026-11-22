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

test "edits: applies one replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{.{ .start = 10, .end = 18, .text = "Number.parseInt" }};
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "const n = parseInt(x);\n");

    try std.testing.expectEqualStrings("const n = Number.parseInt(x);\n", result);
}

test "edits: an empty replacement deletes the span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{.{ .start = 5, .end = 11, .text = "" }};
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "keep DELETE keep\n");

    try std.testing.expectEqualStrings("keep  keep\n", result);
}

test "edits: applies unsorted edits in position order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 8, .end = 9, .text = "two" },
        .{ .start = 0, .end = 3, .text = "one" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaa bbb c ddd\n");

    try std.testing.expectEqualStrings("one bbb two ddd\n", result);
}

test "edits: same range with different text keeps the first input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 0, .end = 4, .text = "kept" },
        .{ .start = 0, .end = 4, .text = "lost" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaaa rest\n");

    try std.testing.expectEqualStrings("kept rest\n", result);
    try std.testing.expectEqual(@as(usize, 1), selection.accepted.len);
    try std.testing.expectEqual(@as(usize, 0), selection.accepted[0].input_index);
    try std.testing.expectEqualStrings("kept", selection.accepted[0].edit.text);
    try std.testing.expectEqual(@as(usize, 1), selection.rejected.len);
    try std.testing.expectEqual(@as(usize, 1), selection.rejected[0].input_index);
    try std.testing.expectEqualStrings("lost", selection.rejected[0].edit.text);
    try std.testing.expectEqual(edits.RejectionReason.conflict, selection.rejected[0].reason);
}

test "edits: same start with different ends keeps the shortest edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 0, .end = 8, .text = "lost" },
        .{ .start = 0, .end = 4, .text = "kept" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("keptbbbbcccc\n", result);
    try std.testing.expectEqual(@as(usize, 1), selection.accepted[0].input_index);
    try std.testing.expectEqual(@as(usize, 0), selection.rejected[0].input_index);
    try std.testing.expectEqual(edits.RejectionReason.conflict, selection.rejected[0].reason);
}

test "edits: crossing overlap rejects the later edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 0, .end = 8, .text = "first" },
        .{ .start = 4, .end = 12, .text = "second" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("firstcccc\n", result);
    try std.testing.expectEqual(@as(usize, 1), selection.accepted.len);
    try std.testing.expectEqual(@as(usize, 1), selection.rejected.len);
    try std.testing.expectEqual(edits.RejectionReason.conflict, selection.rejected[0].reason);
}

test "edits: exact duplicate is distinct from a conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 0, .end = 4, .text = "same" },
        .{ .start = 0, .end = 4, .text = "same" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaaa rest\n");

    try std.testing.expectEqualStrings("same rest\n", result);
    try std.testing.expectEqual(@as(usize, 1), selection.accepted.len);
    try std.testing.expectEqual(@as(usize, 1), selection.rejected.len);
    try std.testing.expectEqual(edits.RejectionReason.duplicate, selection.rejected[0].reason);
}

test "edits: adjacent edits are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 0, .end = 4, .text = "left" },
        .{ .start = 4, .end = 8, .text = "right" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("leftrightcccc\n", result);
    try std.testing.expectEqual(@as(usize, 2), selection.accepted.len);
    try std.testing.expectEqual(@as(usize, 0), selection.rejected.len);
}

test "edits: two insertions at the same position keep the first input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{
        .{ .start = 1, .end = 1, .text = "first" },
        .{ .start = 1, .end = 1, .text = "second" },
    };
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);
    const result = try selection.apply(arena.allocator(), "ab\n");

    try std.testing.expectEqualStrings("afirstb\n", result);
    try std.testing.expectEqual(@as(usize, 0), selection.accepted[0].input_index);
    try std.testing.expectEqual(@as(usize, 1), selection.rejected[0].input_index);
    try std.testing.expectEqual(edits.RejectionReason.conflict, selection.rejected[0].reason);
}

test "edits: apply rejects a range outside the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]edits.Edit{.{ .start = 0, .end = 4, .text = "text" }};
    const selection = try edits.selectNonOverlapping(arena.allocator(), &list);

    try std.testing.expectError(error.InvalidEditRange, selection.apply(arena.allocator(), "abc"));
}

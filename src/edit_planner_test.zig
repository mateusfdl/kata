const std = @import("std");

const planner = @import("edit_planner.zig");

test "edit planner: applies one replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{.{ .start = 10, .end = 18, .text = "Number.parseInt" }};
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "const n = parseInt(x);\n");

    try std.testing.expectEqualStrings("const n = Number.parseInt(x);\n", result);
}

test "edit planner: an empty replacement deletes the span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{.{ .start = 5, .end = 11, .text = "" }};
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "keep DELETE keep\n");

    try std.testing.expectEqualStrings("keep  keep\n", result);
}

test "edit planner: applies unsorted edits in position order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 8, .end = 9, .text = "two" },
        .{ .start = 0, .end = 3, .text = "one" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaa bbb c ddd\n");

    try std.testing.expectEqualStrings("one bbb two ddd\n", result);
}

test "edit planner: same range with different text keeps the first input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 0, .end = 4, .text = "kept" },
        .{ .start = 0, .end = 4, .text = "lost" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaaa rest\n");

    try std.testing.expectEqualStrings("kept rest\n", result);
    try std.testing.expectEqual(@as(usize, 1), plan.accepted.len);
    try std.testing.expectEqual(@as(usize, 0), plan.accepted[0].priority);
    try std.testing.expectEqualStrings("kept", plan.accepted[0].edit.text);
    try std.testing.expectEqual(@as(usize, 1), plan.rejected.len);
    try std.testing.expectEqual(@as(usize, 1), plan.rejected[0].priority);
    try std.testing.expectEqualStrings("lost", plan.rejected[0].edit.text);
    try std.testing.expectEqual(planner.RejectionReason.conflict, plan.rejected[0].reason);
}

test "edit planner: same start with different ends keeps the shortest edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 0, .end = 8, .text = "lost" },
        .{ .start = 0, .end = 4, .text = "kept" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("keptbbbbcccc\n", result);
    try std.testing.expectEqual(@as(usize, 1), plan.accepted[0].priority);
    try std.testing.expectEqual(@as(usize, 0), plan.rejected[0].priority);
    try std.testing.expectEqual(planner.RejectionReason.conflict, plan.rejected[0].reason);
}

test "edit planner: crossing overlap rejects the later edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 0, .end = 8, .text = "first" },
        .{ .start = 4, .end = 12, .text = "second" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("firstcccc\n", result);
    try std.testing.expectEqual(@as(usize, 1), plan.accepted.len);
    try std.testing.expectEqual(@as(usize, 1), plan.rejected.len);
    try std.testing.expectEqual(planner.RejectionReason.conflict, plan.rejected[0].reason);
}

test "edit planner: exact duplicate is distinct from a conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 0, .end = 4, .text = "same" },
        .{ .start = 0, .end = 4, .text = "same" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaaa rest\n");

    try std.testing.expectEqualStrings("same rest\n", result);
    try std.testing.expectEqual(@as(usize, 1), plan.accepted.len);
    try std.testing.expectEqual(@as(usize, 1), plan.rejected.len);
    try std.testing.expectEqual(planner.RejectionReason.duplicate, plan.rejected[0].reason);
}

test "edit planner: adjacent edits are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 0, .end = 4, .text = "left" },
        .{ .start = 4, .end = 8, .text = "right" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "aaaabbbbcccc\n");

    try std.testing.expectEqualStrings("leftrightcccc\n", result);
    try std.testing.expectEqual(@as(usize, 2), plan.accepted.len);
    try std.testing.expectEqual(@as(usize, 0), plan.rejected.len);
}

test "edit planner: two insertions at the same position keep the first input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{
        .{ .start = 1, .end = 1, .text = "first" },
        .{ .start = 1, .end = 1, .text = "second" },
    };
    const plan = try planner.plan(arena.allocator(), &list);
    const result = try plan.apply(arena.allocator(), "ab\n");

    try std.testing.expectEqualStrings("afirstb\n", result);
    try std.testing.expectEqual(@as(usize, 0), plan.accepted[0].priority);
    try std.testing.expectEqual(@as(usize, 1), plan.rejected[0].priority);
    try std.testing.expectEqual(planner.RejectionReason.conflict, plan.rejected[0].reason);
}

test "edit planner: apply rejects a range outside the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list = [_]planner.Edit{.{ .start = 0, .end = 4, .text = "text" }};
    const plan = try planner.plan(arena.allocator(), &list);

    try std.testing.expectError(error.InvalidEditRange, plan.apply(arena.allocator(), "abc"));
}

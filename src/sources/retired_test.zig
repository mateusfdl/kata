const std = @import("std");

const retired = @import("retired.zig");

fn parseOk(arena: std.mem.Allocator, source: []const u8) !retired.Registry {
    var diag: retired.Diagnostic = .{};
    return retired.parse(arena, source, &diag);
}

fn expectParseErr(source: []const u8, expected_err: anyerror, expected_line: u32) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diag: retired.Diagnostic = .{};
    try std.testing.expectError(expected_err, retired.parse(arena_state.allocator(), source, &diag));
    try std.testing.expectEqual(expected_line, diag.line);
}

test "retired: parses a replaced-by entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry = try parseOk(arena_state.allocator(), "old-id:\n  replaced-by: new-id\n");

    switch (registry.get("old-id").?) {
        .replaced => |target| try std.testing.expectEqualStrings("new-id", target),
        .removed => return error.TestUnexpectedResult,
    }
}

test "retired: parses a removed entry with reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry = try parseOk(arena_state.allocator(), "gone-id:\n  reason: \"superseded by the families seam\"\n");

    switch (registry.get("gone-id").?) {
        .removed => |reason| try std.testing.expectEqualStrings("superseded by the families seam", reason),
        .replaced => return error.TestUnexpectedResult,
    }
}

test "retired: replaced-by wins when both keys are present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry = try parseOk(arena_state.allocator(), "old-id:\n  replaced-by: new-id\n  reason: \"also renamed\"\n");

    switch (registry.get("old-id").?) {
        .replaced => |target| try std.testing.expectEqualStrings("new-id", target),
        .removed => return error.TestUnexpectedResult,
    }
}

test "retired: parses multiple entries with comments and blanks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry = try parseOk(arena_state.allocator(),
        \\# header comment
        \\
        \\first-old:
        \\  replaced-by: first-new
        \\
        \\second-old:
        \\  reason: unquoted reason text
        \\
    );

    try std.testing.expectEqual(@as(usize, 2), registry.count());
    switch (registry.get("first-old").?) {
        .replaced => |target| try std.testing.expectEqualStrings("first-new", target),
        .removed => return error.TestUnexpectedResult,
    }
    switch (registry.get("second-old").?) {
        .removed => |reason| try std.testing.expectEqualStrings("unquoted reason text", reason),
        .replaced => return error.TestUnexpectedResult,
    }
}

test "retired: entry without replaced-by or reason fails" {
    try expectParseErr("gone-id:\n", error.MissingRetiredReason, 1);
    try expectParseErr("first:\n  replaced-by: x\ngone-id:\nnext:\n  reason: \"r\"\n", error.MissingRetiredReason, 3);
}

test "retired: property without an entry fails" {
    try expectParseErr("  replaced-by: new-id\n", error.InvalidRetiredEntry, 1);
}

test "retired: unknown property key fails" {
    try expectParseErr("old-id:\n  renamed-to: new-id\n", error.InvalidRetiredEntry, 2);
}

test "retired: top-level line without colon fails" {
    try expectParseErr("old-id\n  reason: \"r\"\n", error.InvalidRetiredEntry, 1);
}

test "retired: embedded registry parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const registry = try parseOk(arena_state.allocator(), retired.embedded_source);

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "retired: merge overlays later tiers over earlier ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = try parseOk(arena, "shared:\n  reason: \"base tier\"\nbase-only:\n  replaced-by: kept\n");
    const overlay = try parseOk(arena, "shared:\n  replaced-by: winner\n");

    try retired.merge(arena, &base, overlay);

    try std.testing.expectEqual(@as(usize, 2), base.count());
    switch (base.get("shared").?) {
        .replaced => |target| try std.testing.expectEqualStrings("winner", target),
        .removed => return error.TestUnexpectedResult,
    }
}

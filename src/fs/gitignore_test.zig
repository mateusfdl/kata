const std = @import("std");

const gitignore = @import("gitignore.zig");

const Expected = struct {
    negated: bool = false,
    dir_only: bool = false,
    anchored: bool = false,
    segments: []const []const u8,
};

fn expectPattern(arena: std.mem.Allocator, line: []const u8, expected: Expected) !void {
    const pattern = (try gitignore.Pattern.parse(arena, line)) orelse return error.TestExpectedPattern;
    try std.testing.expectEqual(expected.negated, pattern.negated);
    try std.testing.expectEqual(expected.dir_only, pattern.dir_only);
    try std.testing.expectEqual(expected.anchored, pattern.anchored);
    try std.testing.expectEqual(expected.segments.len, pattern.segments.len);
    for (expected.segments, pattern.segments) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

fn expectNoPattern(arena: std.mem.Allocator, line: []const u8) !void {
    try std.testing.expect((try gitignore.Pattern.parse(arena, line)) == null);
}

test "gitignore: parse returns null for blank lines and comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectNoPattern(a, "");
    try expectNoPattern(a, "   ");
    try expectNoPattern(a, "# build artifacts");
    try expectNoPattern(a, "#");
    try expectNoPattern(a, "# comment\r");
}

test "gitignore: parse returns null for empty remainders" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectNoPattern(a, "!");
    try expectNoPattern(a, "/");
    try expectNoPattern(a, "!/");
    try expectNoPattern(a, "//");
}

test "gitignore: parse strips carriage returns and unescaped trailing spaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectPattern(a, "foo  ", .{ .segments = &.{"foo"} });
    try expectPattern(a, "foo\r", .{ .segments = &.{"foo"} });
    try expectPattern(a, "foo\\ ", .{ .segments = &.{"foo\\ "} });
    try expectPattern(a, "foo\\  ", .{ .segments = &.{"foo\\ "} });
}

test "gitignore: parse keeps escaped leading bang and hash as literals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectPattern(a, "\\!literal", .{ .segments = &.{"\\!literal"} });
    try expectPattern(a, "\\#literal", .{ .segments = &.{"\\#literal"} });
}

test "gitignore: parse negation and dir-only flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectPattern(a, "!keep.ts", .{ .negated = true, .segments = &.{"keep.ts"} });
    try expectPattern(a, "dist/", .{ .dir_only = true, .segments = &.{"dist"} });
    try expectPattern(a, "!dist/", .{ .negated = true, .dir_only = true, .segments = &.{"dist"} });
}

test "gitignore: parse anchoring from any non-trailing slash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectPattern(a, "/build", .{ .anchored = true, .segments = &.{"build"} });
    try expectPattern(a, "a/b", .{ .anchored = true, .segments = &.{ "a", "b" } });
    try expectPattern(a, "a/b/", .{ .anchored = true, .dir_only = true, .segments = &.{ "a", "b" } });
    try expectPattern(a, "/foo/", .{ .anchored = true, .dir_only = true, .segments = &.{"foo"} });
    try expectPattern(a, "build", .{ .segments = &.{"build"} });
}

test "gitignore: parse double-star segments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectPattern(a, "**/foo", .{ .anchored = true, .segments = &.{ "**", "foo" } });
    try expectPattern(a, "a/**/b", .{ .anchored = true, .segments = &.{ "a", "**", "b" } });
    try expectPattern(a, "a/**", .{ .anchored = true, .segments = &.{ "a", "**" } });
    try expectPattern(a, "**/build/", .{ .anchored = true, .dir_only = true, .segments = &.{ "**", "build" } });
}

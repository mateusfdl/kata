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

fn expectMatches(arena: std.mem.Allocator, line: []const u8, path: []const u8, is_dir: bool, want: bool) !void {
    const pattern = (try gitignore.Pattern.parse(arena, line)) orelse return error.TestExpectedPattern;
    try std.testing.expectEqual(want, pattern.matches(path, is_dir));
}

test "gitignore: unanchored patterns match the basename at any depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "*.min.js", "x.min.js", false, true);
    try expectMatches(a, "*.min.js", "a/b/x.min.js", false, true);
    try expectMatches(a, "*.min.js", "x.min.jsx", false, false);
    try expectMatches(a, "a?c", "a/c", false, false);
    try expectMatches(a, "a?c", "d/abc", false, true);
}

test "gitignore: segment matcher star and question do not cross separators" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "a/*", "a/b", false, true);
    try expectMatches(a, "a/*", "a/b/c", false, false);
    try expectMatches(a, "a/*/c", "a/b/c", false, true);
    try expectMatches(a, "a/*/c", "a/b/d/c", false, false);
    try expectMatches(a, "a/b?", "a/bc", false, true);
    try expectMatches(a, "a/b?", "a/b", false, false);
}

test "gitignore: segment matcher character classes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "[a-c]x", "bx", false, true);
    try expectMatches(a, "[a-c]x", "dx", false, false);
    try expectMatches(a, "[!a]x", "bx", false, true);
    try expectMatches(a, "[!a]x", "ax", false, false);
    try expectMatches(a, "[^a]x", "bx", false, true);
    try expectMatches(a, "[0-9x]y", "xy", false, true);
    try expectMatches(a, "[0-9x]y", "5y", false, true);
    try expectMatches(a, "[0-9x]y", "ay", false, false);
    try expectMatches(a, "[a-]z", "az", false, true);
    try expectMatches(a, "[a-]z", "-z", false, true);
    try expectMatches(a, "[]a]x", "]x", false, true);
    try expectMatches(a, "[]a]x", "ax", false, true);
    try expectMatches(a, "[abc", "[abc", false, true);
    try expectMatches(a, "[abc", "aabc", false, false);
}

test "gitignore: segment matcher backslash escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "\\*x", "*x", false, true);
    try expectMatches(a, "\\*x", "ax", false, false);
    try expectMatches(a, "\\!literal", "!literal", false, true);
    try expectMatches(a, "\\#literal", "#literal", false, true);
    try expectMatches(a, "foo\\ ", "foo ", false, true);
    try expectMatches(a, "foo\\ ", "foo", false, false);
}

test "gitignore: double-star spans directories" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "**/foo", "foo", false, true);
    try expectMatches(a, "**/foo", "x/y/foo", false, true);
    try expectMatches(a, "**/foo", "x/y/food", false, false);
    try expectMatches(a, "a/**", "a", true, false);
    try expectMatches(a, "a/**", "a/b", false, true);
    try expectMatches(a, "a/**", "a/b/c", false, true);
    try expectMatches(a, "a/**/b", "a/b", false, true);
    try expectMatches(a, "a/**/b", "a/x/y/b", false, true);
    try expectMatches(a, "a/**/b", "a/x/y/c", false, false);
}

test "gitignore: dir-only patterns require a directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectMatches(a, "build/", "build", true, true);
    try expectMatches(a, "build/", "build", false, false);
    try expectMatches(a, "build/", "a/build", true, true);
    try expectMatches(a, "**/build/", "a/build", true, true);
    try expectMatches(a, "**/build/", "a/build", false, false);
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

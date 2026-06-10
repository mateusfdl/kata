const std = @import("std");

const walk = @import("walk.zig");

test "walk: appendIgnoredDirs keeps folder entries and skips globs, negation, comments, nested paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    const gitignore =
        "# build artifacts\n" ++
        "node_modules\n" ++
        "dist/\n" ++
        "/build\n" ++
        "  coverage  \n" ++
        "*.log\n" ++
        "!keep-me\n" ++
        "src/generated\n" ++
        "\n";

    try walk.appendIgnoredDirs(arena.allocator(), gitignore, &out);

    const expected = [_][]const u8{ "node_modules", "dist", "build", "coverage" };
    try std.testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "walk: indexPath drops dot target so paths are root relative" {
    const gpa = std.testing.allocator;
    const path = try walk.indexPath(gpa, ".", "src/domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

test "walk: indexPath strips leading dot-slash from target" {
    const gpa = std.testing.allocator;
    const path = try walk.indexPath(gpa, "./src", "domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

test "walk: indexPath joins targets with trailing slash trimmed" {
    const gpa = std.testing.allocator;
    const path = try walk.indexPath(gpa, "src/", "domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

test "walk: appendIgnoredDirs on empty input adds nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    try walk.appendIgnoredDirs(arena.allocator(), "", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

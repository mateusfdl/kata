const std = @import("std");

const lint = @import("engine");
const source = @import("source.zig");
const test_fixture = @import("../test_fixture.zig");

const Collector = struct {
    gpa: std.mem.Allocator,
    prefix_len: usize,
    paths: *std.ArrayList([]const u8),
};

fn collectPath(
    ctx: Collector,
    lang: lint.language.Name,
    bytes: []const u8,
    path: []const u8,
) anyerror!void {
    _ = lang;
    _ = bytes;
    try ctx.paths.append(ctx.gpa, try ctx.gpa.dupe(u8, path[ctx.prefix_len..]));
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn expectVisited(tmp: *std.testing.TmpDir, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var path_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    const ctx = Collector{ .gpa = gpa, .prefix_len = rel.len + 1, .paths = &paths };
    const count = try source.walkFiles(io, gpa, rel, ctx, collectPath);

    std.mem.sort([]const u8, paths.items, {}, pathLessThan);
    try std.testing.expectEqual(expected.len, count);
    try std.testing.expectEqual(expected.len, paths.items.len);
    for (expected, paths.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "walk: gitignore glob patterns prune directories at any depth" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "**/gen/\n" });
    try tmp.dir.createDirPath(io, "a/gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/gen/x.ts", .data = "" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/y.ts", .data = "" });

    try expectVisited(&tmp, &.{"src/y.ts"});
}

test "walk: nested gitignore overrides shallower scopes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "gen/\n" });
    try tmp.dir.createDirPath(io, "gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/a.ts", .data = "" });
    try tmp.dir.createDirPath(io, "pkg/gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/.gitignore", .data = "!gen/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/gen/b.ts", .data = "" });

    try expectVisited(&tmp, &.{"pkg/gen/b.ts"});
}

test "walk: file patterns filter with negation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "gen/*.ts\n!gen/keep.ts\n" });
    try tmp.dir.createDirPath(io, "gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/a.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/keep.ts", .data = "" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.ts", .data = "" });

    try expectVisited(&tmp, &.{ "gen/keep.ts", "src/ok.ts" });
}

test "walk: built-in defaults apply without any gitignore" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/dep.ts", .data = "" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/hook.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "" });

    try expectVisited(&tmp, &.{"a.ts"});
}

test "walk: negation inside an excluded directory cannot re-include" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "a/\n!a/b/keep.ts\n" });
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/keep.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/drop.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.ts", .data = "" });

    try expectVisited(&tmp, &.{"ok.ts"});
}

test "walk: indexPath drops dot target so paths are root relative" {
    const gpa = std.testing.allocator;
    const path = try source.indexPath(gpa, ".", "src/domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

test "walk: indexPath strips leading dot-slash from target" {
    const gpa = std.testing.allocator;
    const path = try source.indexPath(gpa, "./src", "domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

test "walk: indexPath joins targets with trailing slash trimmed" {
    const gpa = std.testing.allocator;
    const path = try source.indexPath(gpa, "src/", "domain/user.ts");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("src/domain/user.ts", path);
}

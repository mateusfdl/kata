const std = @import("std");

const git = @import("git");
const test_fixture = @import("../test_fixture.zig");

const test_limit: usize = 64 * 1024;

fn initRepoWithCommit(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const a = 1;\n" });
    try test_fixture.runGit(gpa, io, tmp.dir, &.{ "git", "init", "-q" });
    try test_fixture.runGit(gpa, io, tmp.dir, &.{ "git", "add", "." });
    try test_fixture.runGit(gpa, io, tmp.dir, &.{
        "git",                  "-c",                   "user.name=kata",
        "-c",                   "user.email=kata@test", "-c",
        "commit.gpgsign=false", "commit",               "-q",
        "-m",                   "base",
    });
}

test "git: showFile returns content committed at the ref" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initRepoWithCommit(gpa, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const changed = 2;\n" });

    const content = try git.showFile(io, gpa, tmp.dir, "HEAD", "a.ts", test_limit) orelse return error.TestUnexpectedResult;
    defer gpa.free(content);

    try std.testing.expectEqualStrings("const a = 1;\n", content);
}

test "git: showFile returns null for a path absent at the ref" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initRepoWithCommit(gpa, io, &tmp);

    const content = try git.showFile(io, gpa, tmp.dir, "HEAD", "missing.ts", test_limit);

    try std.testing.expectEqual(@as(?[]u8, null), content);
}

test "git: verifyRef accepts a commit ref and rejects garbage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initRepoWithCommit(gpa, io, &tmp);

    try git.verifyRef(io, gpa, tmp.dir, "HEAD");
    try std.testing.expectError(error.UnknownRef, git.verifyRef(io, gpa, tmp.dir, "no-such-ref"));
}

test "git: repoPrefix is empty at the root and the relative dir inside" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initRepoWithCommit(gpa, io, &tmp);
    try tmp.dir.createDirPath(io, "sub");

    const root_prefix = try git.repoPrefix(io, gpa, tmp.dir);
    defer gpa.free(root_prefix);
    try std.testing.expectEqualStrings("", root_prefix);

    const sub = try tmp.dir.openDir(io, "sub", .{});
    const sub_prefix = try git.repoPrefix(io, gpa, sub);
    defer gpa.free(sub_prefix);
    try std.testing.expectEqualStrings("sub/", sub_prefix);
}

test "git: findRoot returns the directory holding a .git dir" {
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "sub/inner");

    var path_buf: [256]u8 = undefined;
    const tmp_rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    var sub_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrint(&sub_buf, "{s}/sub/inner", .{tmp_rel});

    const root = (try git.findRoot(io, arena.allocator(), nested)) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(tmp_rel, root);
}

test "git: findRoot accepts a .git gitdir file" {
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /elsewhere\n" });

    var path_buf: [256]u8 = undefined;
    const tmp_rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    const root = (try git.findRoot(io, arena.allocator(), tmp_rel)) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(tmp_rel, root);
}

test "git: findRoot returns null when no ancestor has .git" {
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const tmp_rel = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);

    try std.testing.expectEqual(@as(?[]const u8, null), try git.findRoot(io, arena.allocator(), tmp_rel));
}

test "git: outside a work tree errors NotAWorkTree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try test_fixture.runGit(gpa, io, tmp.dir, &.{ "git", "--version" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /nonexistent\n" });

    try std.testing.expectError(error.NotAWorkTree, git.verifyRef(io, gpa, tmp.dir, "HEAD"));
    try std.testing.expectError(error.NotAWorkTree, git.repoPrefix(io, gpa, tmp.dir));
}

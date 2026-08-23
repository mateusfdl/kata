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

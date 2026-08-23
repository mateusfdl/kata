const std = @import("std");

const max_control_bytes: usize = std.fs.max_path_bytes + 1;

pub fn verifyRef(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, ref: []const u8) !void {
    const spec = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{ref});
    defer gpa.free(spec);

    const result = try run(io, gpa, dir, &.{ "git", "rev-parse", "--verify", "--quiet", spec }, max_control_bytes);
    gpa.free(result.stdout);
    gpa.free(result.stderr);

    const code = exitCode(result.term) orelse return error.UnknownRef;
    if (code == 0) return;
    if (code == 1) return error.UnknownRef;

    return error.NotAWorkTree;
}

pub fn repoPrefix(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const result = try run(io, gpa, dir, &.{ "git", "rev-parse", "--show-prefix" }, max_control_bytes);
    gpa.free(result.stderr);

    if ((exitCode(result.term) orelse 1) != 0) {
        gpa.free(result.stdout);
        return error.NotAWorkTree;
    }

    defer gpa.free(result.stdout);

    return gpa.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\n"));
}

pub fn showFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    ref: []const u8,
    repo_path: []const u8,
    limit: usize,
) !?[]u8 {
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ ref, repo_path });
    defer gpa.free(spec);

    const result = run(io, gpa, dir, &.{ "git", "show", spec }, limit) catch |err| switch (err) {
        error.StreamTooLong => return null,

        else => return err,
    };
    gpa.free(result.stderr);

    if ((exitCode(result.term) orelse 1) != 0) {
        gpa.free(result.stdout);
        return null;
    }

    return result.stdout;
}

pub fn listFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    ref: []const u8,
    repo_path: []const u8,
    limit: usize,
) ![]const []const u8 {
    const result = try run(io, gpa, dir, &.{ "git", "ls-tree", "-r", "--name-only", ref, "--", repo_path }, limit);
    defer gpa.free(result.stdout);
    gpa.free(result.stderr);

    if ((exitCode(result.term) orelse 1) != 0) return &.{};

    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        try files.append(gpa, try gpa.dupe(u8, line));
    }

    return files.toOwnedSlice(gpa);
}

fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    argv: []const []const u8,
    limit: usize,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(limit),
    });
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,

        else => null,
    };
}

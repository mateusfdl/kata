const std = @import("std");

const source = @import("source.zig");

pub fn verifyRef(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, ref: []const u8) !void {
    const spec = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{ref});
    defer gpa.free(spec);

    const result = try run(io, gpa, dir, &.{ "git", "rev-parse", "--verify", "--quiet", spec });
    gpa.free(result.stdout);
    gpa.free(result.stderr);

    const code = exitCode(result.term) orelse return error.UnknownRef;
    if (code == 0) return;
    if (code == 1) return error.UnknownRef;

    return error.NotAWorkTree;
}

pub fn repoPrefix(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const result = try run(io, gpa, dir, &.{ "git", "rev-parse", "--show-prefix" });
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
) !?[]u8 {
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ ref, repo_path });
    defer gpa.free(spec);

    const result = run(io, gpa, dir, &.{ "git", "show", spec }) catch |err| switch (err) {
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

fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(source.max_file_bytes),
    });
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,

        else => null,
    };
}

const std = @import("std");

const paths = @import("path");

pub const project_dir_name = ".kata";

pub fn findProjectRoot(
    io: std.Io,
    arena: std.mem.Allocator,
    anchor: []const u8,
) !?[]const u8 {
    var candidate = try startDir(io, arena, anchor);
    while (true) {
        const marker = try paths.join(arena, candidate, project_dir_name);
        if (try isDirectory(io, marker)) return candidate;
        candidate = std.fs.path.dirname(candidate) orelse return null;
    }
}

fn startDir(io: std.Io, arena: std.mem.Allocator, anchor: []const u8) ![]const u8 {
    const absolute = try absolutize(io, arena, anchor);
    if (try isDirectory(io, absolute)) return absolute;
    return std.fs.path.dirname(absolute) orelse absolute;
}

fn absolutize(io: std.Io, arena: std.mem.Allocator, anchor: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(anchor)) return std.fs.path.resolve(arena, &.{anchor});
    const cwd = try std.process.currentPathAlloc(io, arena);
    return std.fs.path.resolve(arena, &.{ cwd, anchor });
}

pub fn isDirectory(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return err,
    };
    dir.close(io);
    return true;
}

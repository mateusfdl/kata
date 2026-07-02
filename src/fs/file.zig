const std = @import("std");

pub fn readAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

pub fn readOptionalAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) !?[]u8 {
    return readAlloc(io, allocator, path, limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn stat(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{});
}

pub fn executableMtime(io: std.Io) !i64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    const executable_stat = try stat(io, buf[0..n]);
    return executable_stat.mtime.toMilliseconds();
}

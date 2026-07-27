const std = @import("std");

pub fn spawnDetached(io: std.Io, argv: []const []const u8) void {
    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return;
}

pub fn selfPath(io: std.Io, buf: []u8) ![]const u8 {
    const n = try std.process.executablePath(io, buf);

    return buf[0..n];
}

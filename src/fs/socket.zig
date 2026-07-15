const std = @import("std");

pub const max_path_bytes = std.fs.max_path_bytes;

var teardown_path_buf: [max_path_bytes]u8 = undefined;
var teardown_path_len: usize = 0;

pub fn deleteAbsolute(io: std.Io, socket_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
}

pub fn installTeardown(socket_path: []const u8) void {
    if (socket_path.len >= teardown_path_buf.len) return;
    @memcpy(teardown_path_buf[0..socket_path.len], socket_path);
    teardown_path_buf[socket_path.len] = 0;
    teardown_path_len = socket_path.len;

    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleTeardownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn handleTeardownSignal(_: std.posix.SIG) callconv(.c) void {
    _ = std.os.linux.unlink(teardown_path_buf[0..teardown_path_len :0]);
    std.os.linux.exit_group(0);
}

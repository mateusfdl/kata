const std = @import("std");
const build_options = @import("build_options");

const fs = @import("../fs.zig");
const Env = @import("env.zig").Env;

pub const command = "daemon";

const env_socket = "KATA_SOCKET";
const env_runtime_dir = "XDG_RUNTIME_DIR";

pub fn socketPath(env: Env) ![]const u8 {
    if (env.environ.get(env_socket)) |override| return override;

    return stampedSocketPath(env.arena, env.environ.get(env_runtime_dir), try fs.file.executableMtime(env.io));
}

pub fn stampedSocketPath(
    arena: std.mem.Allocator,
    runtime_dir: ?[]const u8,
    binary_mtime: i64,
) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/kata-{s}-{d}.sock", .{
        runtime_dir orelse "/tmp",
        build_options.version,
        binary_mtime,
    });
}

pub fn autostart(env: Env) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = fs.process.selfPath(env.io, &buf) catch return;
    fs.process.spawnDetached(env.io, &.{ self_path, command });
}

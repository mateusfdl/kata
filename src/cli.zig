const std = @import("std");

const Env = @import("cli/env.zig").Env;
const Exit = @import("cli/exit.zig").Exit;

pub const dispatch = @import("cli/app.zig").dispatch;

const io_buffer_size: usize = 8192;

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdin_buf: [io_buffer_size]u8 = undefined;
    var stdout_buf: [io_buffer_size]u8 = undefined;
    var stderr_buf: [io_buffer_size]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);

    const env: Env = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
        .color = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false,
    };

    const argv = init.minimal.args.toSlice(arena) catch |err| return @intFromEnum(unexplained(env.stderr, "read args", err));
    const user_args = if (argv.len > 0) argv[1..] else argv;

    const code = dispatch(env, user_args) catch |err| switch (err) {
        error.UsageReported => Exit.usage,
        error.InternalReported => Exit.internal_error,
        else => unexplained(env.stderr, "kata", err),
    };

    return @intFromEnum(code);
}

// An error that nothing explained on the way up. The message can fail to
// reach a closed stderr; the exit code still tells the caller.
fn unexplained(stderr: *std.Io.Writer, context: []const u8, err: anyerror) Exit {
    stderr.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr.flush() catch {};

    return .internal_error;
}

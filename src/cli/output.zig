//! A failure is explained on stderr once, at the place that understands it, and
//! then travels as `error.UsageReported` or `error.InternalReported`. `cli.main`
//! turns the error into the exit code. No return type needs a failure variant.

const std = @import("std");

pub const usage = @import("cli").usageError;

pub fn failure(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    values: anytype,
) (std.Io.Writer.Error || error{InternalReported}) {
    stderr.print(fmt, values) catch |err| return err;
    stderr.flush() catch |err| return err;

    return error.InternalReported;
}

pub fn internal(
    stderr: *std.Io.Writer,
    context: []const u8,
    err: anyerror,
) (std.Io.Writer.Error || error{InternalReported}) {
    return failure(stderr, "{s}: {s}\n", .{ context, @errorName(err) });
}

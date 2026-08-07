const std = @import("std");

pub fn message(stderr: *std.Io.Writer, text: []const u8, code: u8) !u8 {
    try stderr.writeAll(text);
    try stderr.flush();

    return code;
}

pub fn format(stderr: *std.Io.Writer, comptime fmt: []const u8, values: anytype, code: u8) !u8 {
    try stderr.print(fmt, values);
    try stderr.flush();

    return code;
}

pub fn internal(stderr: *std.Io.Writer, context: []const u8, err: anyerror, code: u8) !u8 {
    return format(stderr, "{s}: {s}\n", .{ context, @errorName(err) }, code);
}

const std = @import("std");

const cli = @import("cli.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (scope == .mvzr) return;
    std.log.defaultLog(level, scope, fmt, args);
}

pub fn main(init: std.process.Init) !void {
    std.process.exit(cli.main(init));
}

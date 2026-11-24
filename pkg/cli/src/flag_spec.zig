const std = @import("std");

pub const prefix = "--";
pub const help = prefix ++ "help";

pub fn isFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, prefix);
}

pub fn text(comptime flag: anytype) []const u8 {
    return prefix ++ flag.name;
}

pub fn isConstant(comptime flag: anytype) bool {
    return @hasField(@TypeOf(flag), "value");
}

pub fn label(comptime flag: anytype) []const u8 {
    return if (isConstant(flag)) text(flag) else text(flag) ++ " " ++ flag.label;
}

pub fn hint(comptime flag: anytype) []const u8 {
    return if (@hasField(@TypeOf(flag), "hint")) flag.hint else "";
}

pub fn texts(comptime flags: anytype) [flags.len][]const u8 {
    var all: [flags.len][]const u8 = undefined;
    inline for (flags, 0..) |flag, index| all[index] = text(flag);
    return all;
}

const std = @import("std");

fn trimTrailingNewline(source: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, source, "\n")) source[0 .. source.len - 1] else source;
}

fn digits(value: usize) usize {
    var n: usize = 1;
    var v = value;

    while (v >= 10) : (v /= 10) n += 1;

    return n;
}


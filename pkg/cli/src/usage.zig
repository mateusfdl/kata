const std = @import("std");

const args = @import("args.zig");
const flag_spec = @import("flag_spec.zig");

pub fn line(comptime words: []const []const u8) []const u8 {
    var text: []const u8 = "usage:";
    for (words) |word| {
        if (word.len > 0) text = text ++ " " ++ word;
    }

    return text ++ "\n";
}

pub fn lines(comptime program: []const u8, comptime command_name: []const u8, comptime forms: anytype) []const u8 {
    var text: []const u8 = "";
    for (forms) |form| {
        text = text ++ line(&.{ program, command_name, form });
    }

    return text;
}

pub fn arguments(comptime Options: type, comptime positionals: anytype, comptime flags: anytype) []const u8 {
    var words: []const []const u8 = &.{};
    for (positionals) |positional| {
        words = words ++ .{argument(Options, positional.field, positional.label)};
    }

    var start: usize = 0;
    while (start < flags.len) {
        const end = alternativesEnd(flags, start);

        words = words ++ .{argument(Options, flags[start].field, alternatives(flags, start, end))};

        start = end;
    }

    return join(words);
}

fn argument(comptime Options: type, comptime field: std.meta.FieldEnum(Options), comptime label: []const u8) []const u8 {
    return if (args.isRequired(Options, field)) label else "[" ++ label ++ "]";
}

fn alternativesEnd(comptime flags: anytype, comptime start: usize) usize {
    var end = start + 1;
    if (!flag_spec.isConstant(flags[start])) return end;

    while (end < flags.len and flag_spec.isConstant(flags[end]) and flags[end].field == flags[start].field) end += 1;
    return end;
}

fn alternatives(comptime flags: anytype, comptime start: usize, comptime end: usize) []const u8 {
    var text: []const u8 = flag_spec.label(flags[start]);
    for (start + 1..end) |index| {
        text = text ++ "|" ++ flag_spec.label(flags[index]);
    }

    return text;
}

fn join(comptime words: []const []const u8) []const u8 {
    var text: []const u8 = "";
    for (words, 0..) |word, index| {
        text = text ++ (if (index == 0) "" else " ") ++ word;
    }

    return text;
}

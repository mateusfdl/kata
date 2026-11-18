const std = @import("std");

const args = @import("args.zig");

const Format = enum { pretty, json, text };

const Options = struct {
    text: []const u8,
    target: []const u8 = ".",
    lang: ?[]const u8 = null,
    format: Format = .pretty,
};

const grammar = args.grammar(Options, .{
    .flags = .{
        .{ .name = "lang", .field = .lang },
        .{ .name = "json", .field = .format, .value = .json },
        .{ .name = "text", .field = .format, .value = .text },
    },
    .positionals = .{ .text, .target },
});

fn expectParse(expected: grammar.Result, argv: []const [:0]const u8) !void {
    try std.testing.expectEqualDeep(expected, grammar.parse(argv));
}

test "grammar: fields that no argument sets keep their defaults" {
    try expectParse(.{ .ok = .{ .text = "rule" } }, &.{"rule"});
}

test "grammar: positionals fill their fields in order" {
    try expectParse(.{ .ok = .{ .text = "rule", .target = "src" } }, &.{ "rule", "src" });
}

test "grammar: a value flag takes the next argument" {
    try expectParse(.{ .ok = .{ .text = "rule", .lang = "ts" } }, &.{ "--lang", "ts", "rule" });
}

test "grammar: a value flag takes the text after '='" {
    try expectParse(.{ .ok = .{ .text = "rule", .lang = "ts" } }, &.{ "rule", "--lang=ts" });
}

test "grammar: '--flag=' yields an empty value" {
    try expectParse(.{ .ok = .{ .text = "rule", .lang = "" } }, &.{ "rule", "--lang=" });
}

test "grammar: '--flag=' accepts a value that begins with '--'" {
    try expectParse(.{ .ok = .{ .text = "rule", .lang = "--json" } }, &.{ "rule", "--lang=--json" });
}

test "grammar: a constant flag assigns its value" {
    try expectParse(.{ .ok = .{ .text = "rule", .format = .json } }, &.{ "rule", "--json" });
}

test "grammar: the last flag that targets a field wins" {
    try expectParse(.{ .ok = .{ .text = "rule", .format = .text } }, &.{ "--json", "rule", "--text" });
    try expectParse(.{ .ok = .{ .text = "rule", .format = .json } }, &.{ "--text", "rule", "--json" });
}

test "grammar: a value flag at the end has no value" {
    try expectParse(.{ .invalid = .{ .missing_value = "--lang" } }, &.{ "rule", "--lang" });
}

test "grammar: a value flag does not take another flag as its value" {
    try expectParse(.{ .invalid = .{ .missing_value = "--lang" } }, &.{ "rule", "--lang", "--json" });
}

test "grammar: an unknown flag is unexpected" {
    try expectParse(.{ .invalid = .{ .unexpected = "--format" } }, &.{ "rule", "--format", "json" });
}

test "grammar: a constant flag refuses a value" {
    try expectParse(.{ .invalid = .{ .unexpected = "--json=yes" } }, &.{ "rule", "--json=yes" });
}

test "grammar: a positional beyond the declared ones is unexpected" {
    try expectParse(.{ .invalid = .{ .unexpected = "extra" } }, &.{ "rule", "src", "extra" });
}

test "grammar: a positional without a default is required" {
    try expectParse(.{ .invalid = .missing_positional }, &.{"--json"});
}

test "grammar: the first invalid argument is the one reported" {
    try expectParse(.{ .invalid = .{ .unexpected = "extra" } }, &.{ "rule", "src", "extra", "--bogus", "--lang" });
}

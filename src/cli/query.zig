const std = @import("std");

const check = @import("check.zig");
const lint = @import("../lint.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const Outcome = enum { clean, matches, usage };

pub const Options = struct {
    text: []const u8 = "",
    target: []const u8 = ".",
    lang: []const u8 = "",
    invalid_arg: ?[]const u8 = null,
};

pub const usage_line = "usage: kata query '<scm>' [path] --lang=<ts|tsx|go>\n";

const rule_id = "query";

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    registry: *language.Registry,
    opts: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Outcome {
    if (opts.invalid_arg) |arg|
        return usageError(stderr, "kata query: unexpected argument \"{s}\" (is the query quoted?)\n", .{arg});
    if (opts.text.len == 0)
        return usageError(stderr, usage_line, .{});
    if (opts.lang.len == 0)
        return usageError(stderr, "kata query: --lang is required (expected " ++ language.supported_list ++ ")\n", .{});
    const lang = language.Name.fromString(opts.lang) orelse
        return usageError(stderr, "kata query: unsupported language: \"{s}\" (expected " ++ language.supported_list ++ ")\n", .{opts.lang});

    var rule_set: lint.RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();
    try rule_set.append(lang, .{ .id = rule_id, .language = lang, .source = opts.text });

    var engine = Engine.init(gpa, registry, &rule_set);
    defer engine.deinit();

    engine.prewarm() catch {
        try engine.compile_diag.write("kata", stderr);
        return .usage;
    };

    return switch (try check.run(io, gpa, &engine, opts.target, &.{}, stdout)) {
        .clean => .clean,
        .violations => .matches,
    };
}

fn usageError(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !Outcome {
    try stderr.print(fmt, args);
    try stderr.flush();
    return .usage;
}

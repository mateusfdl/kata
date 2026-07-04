const std = @import("std");

const check = @import("check.zig");
const lint = @import("../lint.zig");
const reports = @import("../reports.zig");

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
    var langs_buf: [language.max_langs_per_dir]language.Name = undefined;
    var langs_len: usize = 0;
    var it = std.mem.splitScalar(u8, opts.lang, ',');
    while (it.next()) |token| {
        const lang = language.Name.fromString(token) orelse
            return usageError(stderr, "kata query: unsupported language: \"{s}\" (expected " ++ language.supported_list ++ ")\n", .{token});
        if (containsLang(langs_buf[0..langs_len], lang)) continue;
        langs_buf[langs_len] = lang;
        langs_len += 1;
    }

    var rule_set: lint.RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();
    for (langs_buf[0..langs_len]) |lang| {
        try rule_set.append(lang, .{ .id = rule_id, .language = lang, .source = opts.text });
    }

    var engine = Engine.init(gpa, registry, &rule_set);
    defer engine.deinit();

    if (!try engine.prewarmOrReport("kata", stderr)) return .usage;

    var reporter: reports.Reporter = .{ .text = .{ .writer = stdout } };
    return switch (try check.run(io, gpa, &engine, opts.target, &.{}, &reporter)) {
        .clean => .clean,
        .violations => .matches,
    };
}

fn containsLang(langs: []const language.Name, lang: language.Name) bool {
    for (langs) |l| {
        if (l == lang) return true;
    }
    return false;
}

fn usageError(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !Outcome {
    try stderr.print(fmt, args);
    try stderr.flush();
    return .usage;
}

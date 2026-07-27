const std = @import("std");

const args_mod = @import("args.zig");
const exit = @import("exit.zig");
const output = @import("output.zig");
const lint = @import("engine");
const server = @import("../server.zig");

const Engine = lint.Engine;
const diagnostic = lint.diagnostic;
const language = lint.language;
const daemon = server.daemon;
const protocol = server.protocol;

pub const Options = struct {
    args: []const [:0]const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const usage_line = "usage: kata --lang=<ts|tsx|go> [--filename=<path>] < source\n";

pub fn run(
    allocator: std.mem.Allocator,
    ctx: daemon.Context,
    opts: Options,
) !u8 {
    const parsed = parseFlags(opts.args) catch return try usageError(opts.stderr);

    if (!try ctx.engine.prewarmOrReport("kata", opts.stderr)) return exit.internal_error;

    const lang = switch (language.resolve(parsed.lang_flag, parsed.filename)) {
        .ok => |n| n,
        .missing => return try output.message(opts.stderr, "missing --lang (or provide --filename with a known extension)\n", exit.usage),
        .unknown_extension => |ext| return try output.format(opts.stderr, "cannot infer language from extension \"{s}\"\n", .{ext}, exit.usage),
        .unsupported_language => |name| return try output.format(opts.stderr, "lint: unsupported language: \"{s}\"\n", .{name}, exit.internal_error),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = opts.stdin.allocRemaining(arena.allocator(), .unlimited) catch |err|
        return try output.internal(opts.stderr, "read stdin", err, exit.internal_error);

    const response = daemon.handle(ctx, arena.allocator(), .{
        .language = lang.toString(),
        .filename = if (parsed.filename.len > 0) parsed.filename else null,
        .source = source,
    });

    const report = response.report orelse
        return try output.format(opts.stderr, "kata: {s}\n", .{response.message orelse "lint failed"}, exit.internal_error);

    writeReport(opts.stdout, report) catch |err|
        return try output.internal(opts.stderr, "encode report", err, exit.internal_error);

    return if (report.clean) exit.clean else exit.violations;
}

fn usageError(stderr: *std.Io.Writer) !u8 {
    return output.message(stderr, usage_line, exit.usage);
}

fn writeReport(stdout: *std.Io.Writer, report: diagnostic.Report) !void {
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
}

pub fn anchorOf(args: []const [:0]const u8) ?[]const u8 {
    const parsed = parseFlags(args) catch return null;
    return if (parsed.filename.len > 0) parsed.filename else null;
}

const ParsedFlags = struct {
    lang_flag: []const u8 = "",
    filename: []const u8 = "",
};

const FlagError = error{ UnknownFlag, MissingValue };

fn parseFlags(args: []const [:0]const u8) FlagError!ParsedFlags {
    var p: ParsedFlags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        switch (args_mod.valueFor(args, &i, .lang)) {
            .found => |value| {
                p.lang_flag = value;
                continue;
            },
            .missing => return error.MissingValue,
            .absent => {},
        }
        switch (args_mod.valueFor(args, &i, .filename)) {
            .found => |value| {
                p.filename = value;
                continue;
            },
            .missing => return error.MissingValue,
            .absent => {},
        }
        return error.UnknownFlag;
    }
    return p;
}

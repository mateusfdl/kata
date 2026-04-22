const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");

pub const exit_clean: u8 = 0;
pub const exit_violations: u8 = 2;
pub const exit_usage: u8 = 64;
pub const exit_internal_error: u8 = 70;

pub const Options = struct {
    args: []const [:0]const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const Report = struct {
    language: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
    clean: bool,
};

const usage_line = "usage: kata --lang=<ts|tsx> [--filename=<path>] < source\n";

pub fn run(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    opts: Options,
) !u8 {
    const parsed = parseFlags(opts.args) catch return try usageError(opts.stderr);

    const lang = switch (try pickLanguage(opts.stderr, parsed)) {
        .lang => |n| n,
        .exit => |code| return code,
    };

    const source = opts.stdin.allocRemaining(allocator, .unlimited) catch |err|
        return try internalError(opts.stderr, "read stdin", err);
    defer allocator.free(source);

    const diagnostics = engine.lint(allocator, source, lang) catch |err|
        return try internalError(opts.stderr, "lint", err);
    defer allocator.free(diagnostics);

    writeReport(opts.stdout, lang, diagnostics) catch |err|
        return try internalError(opts.stderr, "encode report", err);

    return if (diagnostics.len > 0) exit_violations else exit_clean;
}

fn usageError(stderr: *std.Io.Writer) !u8 {
    try stderr.writeAll(usage_line);
    try stderr.flush();
    return exit_usage;
}

fn internalError(stderr: *std.Io.Writer, context: []const u8, err: anyerror) !u8 {
    try stderr.print("{s}: {s}\n", .{ context, @errorName(err) });
    try stderr.flush();
    return exit_internal_error;
}

const LangOrExit = union(enum) {
    lang: language.Name,
    exit: u8,
};

fn pickLanguage(stderr: *std.Io.Writer, parsed: ParsedFlags) !LangOrExit {
    switch (resolveLanguage(parsed.lang_flag, parsed.filename)) {
        .ok => |n| return .{ .lang = n },
        .missing => {
            try stderr.writeAll("missing --lang (or provide --filename with a known extension)\n");
            try stderr.flush();
            return .{ .exit = exit_usage };
        },
        .unknown_extension => |ext| {
            try stderr.print("cannot infer language from extension \"{s}\"\n", .{ext});
            try stderr.flush();
            return .{ .exit = exit_usage };
        },
        .unsupported_language => |name| {
            try stderr.print("lint: unsupported language: \"{s}\"\n", .{name});
            try stderr.flush();
            return .{ .exit = exit_internal_error };
        },
    }
}

fn writeReport(
    stdout: *std.Io.Writer,
    lang: language.Name,
    diagnostics: []const diagnostic.Diagnostic,
) !void {
    const report: Report = .{
        .language = lang.toString(),
        .diagnostics = diagnostics,
        .clean = diagnostics.len == 0,
    };
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
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
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--lang=")) {
            p.lang_flag = a["--lang=".len..];
        } else if (std.mem.eql(u8, a, "--lang")) {
            if (i + 1 >= args.len) return error.MissingValue;
            i += 1;
            p.lang_flag = args[i];
        } else if (std.mem.startsWith(u8, a, "--filename=")) {
            p.filename = a["--filename=".len..];
        } else if (std.mem.eql(u8, a, "--filename")) {
            if (i + 1 >= args.len) return error.MissingValue;
            i += 1;
            p.filename = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return p;
}

const LangResolution = union(enum) {
    ok: language.Name,
    missing,
    unknown_extension: []const u8,
    unsupported_language: []const u8,
};

fn resolveLanguage(lang_flag: []const u8, filename: []const u8) LangResolution {
    if (lang_flag.len > 0) return resolveFromFlag(lang_flag);
    if (filename.len == 0) return .missing;
    return resolveFromFilename(filename);
}

fn resolveFromFlag(lang_flag: []const u8) LangResolution {
    if (language.Name.fromString(lang_flag)) |n| return .{ .ok = n };
    return .{ .unsupported_language = lang_flag };
}

fn resolveFromFilename(filename: []const u8) LangResolution {
    const ext = extOf(filename);
    if (ext.len == 0) return .{ .unknown_extension = ext };

    var buf: [8]u8 = undefined;
    if (ext.len > buf.len) return .{ .unknown_extension = ext };
    for (ext, 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    const ext_lower = buf[0..ext.len];

    if (language.Name.fromExtension(ext_lower)) |n| return .{ .ok = n };
    return .{ .unknown_extension = ext };
}

fn extOf(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') return "";
        if (c == '.') return path[i - 1 ..];
    }
    return "";
}

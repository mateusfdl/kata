const std = @import("std");

const check = @import("check.zig");
const daemon = @import("daemon.zig");
const diagnostic = @import("diagnostic.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const protocol = @import("protocol.zig");

pub const exit_clean: u8 = 0;
pub const exit_violations: u8 = 2;
pub const exit_usage: u8 = 64;
pub const exit_internal_error: u8 = 70;

pub const Command = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    engine: *engine_mod.Engine,
    environ: *std.process.Environ.Map,
    args: []const [:0]const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const Subcommand = union(enum) {
    daemon,
    check: []const u8,
    stop,
    one_shot,
};

fn parseSubcommand(args: []const [:0]const u8) Subcommand {
    if (args.len == 0) return .daemon;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "check")) return .{ .check = firstPositional(args[1..]) orelse "." };
    if (std.mem.eql(u8, cmd, "stop")) return .stop;
    if (std.mem.startsWith(u8, cmd, "--lang") or std.mem.startsWith(u8, cmd, "--filename")) return .one_shot;
    return .daemon;
}

pub fn dispatch(c: Command) !u8 {
    return switch (parseSubcommand(c.args)) {
        .daemon => runDaemon(c),
        .check => |target| runCheck(c, target),
        .stop => runStop(c),
        .one_shot => runOneShot(c),
    };
}

fn runOneShot(c: Command) !u8 {
    return run(c.gpa, c.engine, .{
        .args = c.args,
        .stdin = c.stdin,
        .stdout = c.stdout,
        .stderr = c.stderr,
    });
}

fn runDaemon(c: Command) !u8 {
    c.engine.prewarm() catch |err| return internalError(c.stderr, "prewarm", err);

    const socket_path = resolveSocketPath(c.arena, c.environ, c.args) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    const binary_mtime = daemon.binaryMtime(c.io) catch |err|
        return internalError(c.stderr, "stat executable", err);

    daemon.serve(c.io, c.gpa, .{
        .engine = c.engine,
        .binary_mtime = binary_mtime,
    }, socket_path) catch |err| switch (err) {
        error.AlreadyRunning => {
            try c.stderr.writeAll("kata daemon already running\n");
            try c.stderr.flush();
            return exit_clean;
        },
        else => return internalError(c.stderr, "serve", err),
    };

    return exit_clean;
}

fn runCheck(c: Command, target: []const u8) !u8 {
    const outcome = check.run(c.io, c.gpa, c.engine, target, c.stdout) catch |err| switch (err) {
        error.UnsupportedTarget => {
            try c.stderr.print("cannot infer language from \"{s}\"\n", .{target});
            try c.stderr.flush();
            return exit_usage;
        },
        else => return internalError(c.stderr, "check", err),
    };
    return switch (outcome) {
        .clean => exit_clean,
        .violations => exit_violations,
    };
}

fn runStop(c: Command) !u8 {
    const socket_path = resolveSocketPath(c.arena, c.environ, c.args) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    const address = std.Io.net.UnixAddress.init(socket_path) catch |err|
        return internalError(c.stderr, "socket path", err);

    const stream = address.connect(c.io) catch {
        try c.stderr.writeAll("no kata daemon running\n");
        try c.stderr.flush();
        return exit_clean;
    };
    defer stream.close(c.io);

    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(c.io, &write_buf);
    try protocol.encode(c.arena, &writer.interface, protocol.Request{ .binary_mtime = 0, .shutdown = true });

    try c.stdout.writeAll("kata daemon stopped\n");
    try c.stdout.flush();
    return exit_clean;
}

fn firstPositional(args: []const [:0]const u8) ?[]const u8 {
    for (args) |a| {
        if (!std.mem.startsWith(u8, a, "--")) return a;
    }
    return null;
}

fn resolveSocketPath(
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    args: []const [:0]const u8,
) ![]const u8 {
    if (flagValue(args, "--socket")) |path| return path;
    if (environ.get("KATA_SOCKET")) |path| return path;
    if (environ.get("XDG_RUNTIME_DIR")) |dir|
        return std.fmt.allocPrint(arena, "{s}/kata.sock", .{dir});
    return "/tmp/kata.sock";
}

fn flagValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (args) |a| {
        if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=')
            return a[name.len + 1 ..];
    }
    return null;
}

pub const Options = struct {
    args: []const [:0]const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const usage_line = "usage: kata --lang=<ts|tsx|go> [--filename=<path>] < source\n";

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
    switch (language.resolve(parsed.lang_flag, parsed.filename)) {
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
    const report: diagnostic.Report = .{
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

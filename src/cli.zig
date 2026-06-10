const std = @import("std");

const lint = @import("lint.zig");
const server = @import("server.zig");
const check = @import("cli/check.zig");

const Engine = lint.Engine;
const diagnostic = lint.diagnostic;
const language = lint.language;
const daemon = server.daemon;
const protocol = server.protocol;

pub const exit_clean: u8 = 0;
pub const exit_violations: u8 = 2;
pub const exit_usage: u8 = 64;
pub const exit_internal_error: u8 = 70;

pub const Command = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    engine: *Engine,
    environ: *std.process.Environ.Map,
    args: []const [:0]const u8,
    project_rules: []const lint.project_rule.ProjectRule = &.{},
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const Subcommand = union(enum) {
    daemon,
    check: []const u8,
    facts: []const u8,
    stop,
    one_shot,
    unknown: []const u8,
};

pub fn parseSubcommand(args: []const [:0]const u8) Subcommand {
    if (args.len == 0) return .daemon;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "check")) return .{ .check = firstPositional(args[1..]) orelse "." };
    if (std.mem.eql(u8, cmd, "facts")) return .{ .facts = firstPositional(args[1..]) orelse "" };
    if (std.mem.eql(u8, cmd, "stop")) return .stop;
    if (std.mem.startsWith(u8, cmd, "--")) return .one_shot;
    return .{ .unknown = cmd };
}

pub fn dispatch(c: Command) !u8 {
    return switch (parseSubcommand(c.args)) {
        .daemon => runDaemon(c),
        .check => |target| runCheck(c, target),
        .facts => |target| runFacts(c, target),
        .stop => runStop(c),
        .one_shot => run(c.gpa, c.engine, .{
            .args = c.args,
            .stdin = c.stdin,
            .stdout = c.stdout,
            .stderr = c.stderr,
        }),
        .unknown => |cmd| runUnknown(c, cmd),
    };
}

fn runUnknown(c: Command, cmd: []const u8) !u8 {
    try c.stderr.print("unknown subcommand: \"{s}\"\n", .{cmd});
    try c.stderr.writeAll("usage: kata [check <path> | facts <file> | stop | new-rule <lang> <id> | --lang=<ts|tsx|go>]\n");
    try c.stderr.flush();
    return exit_usage;
}

fn validateRules(engine: *Engine, stderr: *std.Io.Writer) !?u8 {
    engine.prewarm() catch {
        const d = engine.compile_diag;
        if (d.lang) |lang| {
            try stderr.print("kata: rule {s}/{s}: {s}\n", .{ lang.toString(), d.rule_id, d.detail });
        } else {
            try stderr.writeAll("kata: rule compilation failed\n");
        }
        try stderr.flush();
        return exit_internal_error;
    };
    return null;
}

fn runDaemon(c: Command) !u8 {
    if (try validateRules(c.engine, c.stderr)) |code| return code;

    const socket_path = resolveSocketPath(c.arena, c.environ) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    const binary_mtime = daemon.binaryMtime(c.io) catch |err|
        return internalError(c.stderr, "stat executable", err);

    daemon.serve(c.io, c.gpa, .{
        .engine = c.engine,
        .binary_mtime = binary_mtime,
    }, socket_path) catch |err| switch (err) {
        error.AlreadyRunning => return printAndExit(c.stderr, "kata daemon already running\n", exit_clean),
        else => return internalError(c.stderr, "serve", err),
    };

    return exit_clean;
}

fn runCheck(c: Command, target: []const u8) !u8 {
    if (try validateRules(c.engine, c.stderr)) |code| return code;

    const outcome = check.run(c.io, c.gpa, c.engine, target, c.project_rules, c.stdout) catch |err| switch (err) {
        error.UnsupportedTarget => return printfAndExit(c.stderr, "cannot infer language from \"{s}\"\n", .{target}, exit_usage),
        else => return internalError(c.stderr, "check", err),
    };
    return switch (outcome) {
        .clean => exit_clean,
        .violations => exit_violations,
    };
}

fn runFacts(c: Command, target: []const u8) !u8 {
    if (target.len == 0) return printAndExit(c.stderr, "usage: kata facts <file>\n", exit_usage);

    const lang = switch (language.resolve("", target)) {
        .ok => |n| n,
        else => return printfAndExit(c.stderr, "cannot infer language from \"{s}\"\n", .{target}, exit_usage),
    };

    const source = std.Io.Dir.cwd().readFileAlloc(c.io, target, c.gpa, .limited(check.max_file_bytes)) catch |err|
        return internalError(c.stderr, "read file", err);
    defer c.gpa.free(source);

    var file_facts = c.engine.extractFacts(c.gpa, source, lang, target) catch |err|
        return internalError(c.stderr, "extract facts", err);
    defer file_facts.deinit();

    printFacts(c.stdout, file_facts) catch |err|
        return internalError(c.stderr, "print facts", err);
    return exit_clean;
}

fn printFacts(stdout: *std.Io.Writer, file_facts: lint.facts.FileFacts) !void {
    for (file_facts.classes) |cl| {
        try stdout.print("class {s} @{d}:{d}\n", .{ cl.name, cl.range.start.line + 1, cl.range.start.column + 1 });
    }
    for (file_facts.methods) |m| {
        try stdout.print("method {s}.{s} @{d}:{d}\n", .{ orDash(m.container), m.name, m.range.start.line + 1, m.range.start.column + 1 });
    }
    for (file_facts.typed_decls) |d| {
        try stdout.print("decl {s}: {s} @{d}:{d}\n", .{ d.name, d.type_name, d.range.start.line + 1, d.range.start.column + 1 });
    }
    for (file_facts.calls) |call| {
        try stdout.print("call {s}.{s} in {s} @{d}:{d}\n", .{ orDash(call.receiver), call.method, orDash(call.container), call.range.start.line + 1, call.range.start.column + 1 });
    }
    for (file_facts.imports) |im| {
        try stdout.print("import {s} from {s}\n", .{ orDash(im.name), im.source });
    }
    try stdout.flush();
}

fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

fn runStop(c: Command) !u8 {
    const socket_path = resolveSocketPath(c.arena, c.environ) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    const address = std.Io.net.UnixAddress.init(socket_path) catch |err|
        return internalError(c.stderr, "socket path", err);

    const stream = address.connect(c.io) catch return printAndExit(c.stderr, "no kata daemon running\n", exit_clean);
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
) ![]const u8 {
    if (environ.get("KATA_SOCKET")) |path| return path;
    if (environ.get("XDG_RUNTIME_DIR")) |dir|
        return std.fmt.allocPrint(arena, "{s}/kata.sock", .{dir});
    return "/tmp/kata.sock";
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
    engine: *Engine,
    opts: Options,
) !u8 {
    const parsed = parseFlags(opts.args) catch return try usageError(opts.stderr);

    if (try validateRules(engine, opts.stderr)) |code| return code;

    const lang = switch (language.resolve(parsed.lang_flag, parsed.filename)) {
        .ok => |n| n,
        .missing => return try printAndExit(opts.stderr, "missing --lang (or provide --filename with a known extension)\n", exit_usage),
        .unknown_extension => |ext| return try printfAndExit(opts.stderr, "cannot infer language from extension \"{s}\"\n", .{ext}, exit_usage),
        .unsupported_language => |name| return try printfAndExit(opts.stderr, "lint: unsupported language: \"{s}\"\n", .{name}, exit_internal_error),
    };

    const source = opts.stdin.allocRemaining(allocator, .unlimited) catch |err|
        return try internalError(opts.stderr, "read stdin", err);
    defer allocator.free(source);

    const diagnostics = engine.lint(allocator, source, lang, parsed.filename) catch |err|
        return try internalError(opts.stderr, "lint", err);
    defer allocator.free(diagnostics);

    writeReport(opts.stdout, lang, diagnostics) catch |err|
        return try internalError(opts.stderr, "encode report", err);

    return if (diagnostics.len > 0) exit_violations else exit_clean;
}

fn printAndExit(stderr: *std.Io.Writer, message: []const u8, code: u8) !u8 {
    try stderr.writeAll(message);
    try stderr.flush();
    return code;
}

fn printfAndExit(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype, code: u8) !u8 {
    try stderr.print(fmt, args);
    try stderr.flush();
    return code;
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

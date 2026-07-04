const std = @import("std");

const fs = @import("fs.zig");
const lint = @import("lint.zig");
const server = @import("server.zig");
const sources = @import("sources.zig");
const args_mod = @import("cli/args.zig");
const check = @import("cli/check.zig");
const exit = @import("cli/exit.zig");
const facts = @import("cli/facts.zig");
const harness = @import("cli/harness.zig");
const new_rule = @import("cli/new_rule.zig");
const one_shot = @import("cli/one_shot.zig");
const output = @import("cli/output.zig");
const query = @import("cli/query.zig");

const Engine = lint.Engine;
const language = lint.language;
const daemon = server.daemon;
const protocol = server.protocol;
const config = sources.config;
const loader_mod = sources.loader;

const io_buffer_size: usize = 8192;

pub const exit_clean = exit.clean;
pub const exit_violations = exit.violations;
pub const exit_usage = exit.usage;
pub const exit_internal_error = exit.internal_error;

pub const Command = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    engine: *Engine,
    environ: *std.process.Environ.Map,
    args: []const [:0]const u8,
    project_rules: []const lint.project_rule.ProjectRule = &.{},
    user_rules_dir: ?[]const u8 = null,
    ratchet: bool = false,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const Subcommand = union(enum) {
    daemon: ?[]const u8,
    check: []const u8,
    facts: []const u8,
    rule_test: []const u8,
    query: query.Options,
    stop,
    new_rule,
    one_shot,
    unknown: []const u8,
};

pub fn parseSubcommand(args: []const [:0]const u8) Subcommand {
    if (args.len == 0) return .{ .daemon = null };
    const cmd = args[0];
    if (args_mod.isFlag(cmd)) return .one_shot;
    return switch (args_mod.CommandName.parse(cmd) orelse return .{ .unknown = cmd }) {
        .daemon => .{ .daemon = rootFlag(args[1..]) },
        .check => .{ .check = args_mod.firstPositional(args[1..]) orelse "." },
        .facts => .{ .facts = args_mod.firstPositional(args[1..]) orelse "" },
        .@"test" => .{ .rule_test = args_mod.firstPositional(args[1..]) orelse "" },
        .query => .{ .query = parseQueryArgs(args[1..]) },
        .stop => .stop,
        .@"new-rule" => .new_rule,
    };
}

fn parseQueryArgs(args: []const [:0]const u8) query.Options {
    var q: query.Options = .{};
    var positionals: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        switch (args_mod.valueFor(args, &i, .lang)) {
            .found => |value| {
                q.lang = value;
                continue;
            },
            .missing => continue,
            .absent => {},
        }

        if (args_mod.isFlag(a)) {
            if (q.invalid_arg == null) q.invalid_arg = a;
            continue;
        }

        positionals += 1;

        switch (positionals) {
            1 => q.text = a,
            2 => q.target = a,
            else => if (q.invalid_arg == null) {
                q.invalid_arg = a;
            },
        }
    }

    return q;
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var stdin_buf: [io_buffer_size]u8 = undefined;
    var stdout_buf: [io_buffer_size]u8 = undefined;
    var stderr_buf: [io_buffer_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const argv = init.minimal.args.toSlice(arena) catch |err| return die(stderr, "read args", err);
    const user_args = if (argv.len > 0) argv[1..] else argv;
    const user_dir = resolveUserRulesDir(arena, init.environ_map) catch |err| return die(stderr, "resolve user rules dir", err);

    const subcommand = parseSubcommand(user_args);
    if (subcommand == .new_rule) {
        return runNewRule(arena, io, user_args, user_dir, &stdout_writer.interface, stderr) catch |err|
            die(stderr, "new-rule", err);
    }

    var registry = language.Registry.init();
    var rule_set = loader_mod.load(arena, io, .{
        .external_dir = init.environ_map.get(args_mod.env_rules_dir),
        .user_dir = user_dir,
    }) catch |err| return die(stderr, "load rules", err);
    defer rule_set.deinit();

    drainWarnings(stderr, &rule_set);

    var diag: config.Diagnostic = .{};
    var cfg_opt = config.loadFromDisk(gpa, io, init.environ_map, &diag) catch |err| return dieConfig(stderr, diag, err);
    defer if (cfg_opt) |*cfg| cfg.deinit();
    const resolved = config.resolve(if (cfg_opt) |*cfg| cfg else null, null);
    config.filterDisabled(&rule_set, resolved);

    var engine = Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();
    engine.metrics = resolved.metrics;
    engine.warnings = resolved.warnings;

    return dispatchSubcommand(.{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .engine = &engine,
        .environ = init.environ_map,
        .args = user_args,
        .project_rules = resolved.project_rules,
        .user_rules_dir = user_dir,
        .ratchet = resolved.ratchet,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = stderr,
    }, subcommand) catch |err| die(stderr, "kata", err);
}

fn rootFlag(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        switch (args_mod.valueFor(args, &i, .root)) {
            .found => |value| return value,
            .missing => return null,
            .absent => {},
        }
    }
    return null;
}

pub fn dispatch(c: Command) !u8 {
    return dispatchSubcommand(c, parseSubcommand(c.args));
}

fn dispatchSubcommand(c: Command, subcommand: Subcommand) !u8 {
    return switch (subcommand) {
        .daemon => |root| runDaemon(c, root),
        .check => |target| runCheck(c, target),
        .facts => |target| runFacts(c, target),
        .rule_test => |dir| runRuleTest(c, dir),
        .query => |q| runQuery(c, q),
        .stop => runStop(c),
        .new_rule => runNewRule(c.arena, c.io, c.args, c.user_rules_dir, c.stdout, c.stderr),
        .one_shot => one_shot.run(c.gpa, c.engine, .{
            .args = c.args,
            .stdin = c.stdin,
            .stdout = c.stdout,
            .stderr = c.stderr,
        }),
        .unknown => |cmd| runUnknown(c, cmd),
    };
}

fn runNewRule(
    arena: std.mem.Allocator,
    io: std.Io,
    command_args: []const [:0]const u8,
    user_rules_dir: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    return new_rule.run(arena, io, .{
        .args = command_args,
        .user_rules_dir = user_rules_dir,
        .stdout = stdout,
        .stderr = stderr,
    });
}

fn runUnknown(c: Command, cmd: []const u8) !u8 {
    try c.stderr.print("unknown subcommand: \"{s}\"\n", .{cmd});
    try c.stderr.writeAll("usage: kata [daemon [--root <dir>] | check <path> | facts <file> | test <rules-dir> | query <scm> [path] --lang=<lang> | stop | new-rule <lang> <id> | --lang=<ts|tsx|go>]\n");
    try c.stderr.flush();
    return exit_usage;
}

fn runDaemon(c: Command, root: ?[]const u8) !u8 {
    if (!try c.engine.prewarmOrReport("kata", c.stderr)) return exit_internal_error;

    const socket_path = resolveSocketPath(c.arena, c.environ) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    const binary_mtime = daemon.binaryMtime(c.io) catch |err|
        return internalError(c.stderr, "stat executable", err);

    var project_state: ?daemon.ProjectState = null;
    defer if (project_state) |*p| p.deinit();
    if (root) |r| {
        if (c.project_rules.len == 0)
            return printAndExit(c.stderr, "kata daemon --root requires project-rules in rules.yaml\n", exit_usage);
        project_state = daemon.ProjectState.init(c.gpa, c.project_rules);
        _ = daemon.buildIndex(c.io, c.gpa, c.engine, r, &project_state.?) catch |err|
            return internalError(c.stderr, "index project", err);
    }

    daemon.serve(c.gpa, .{
        .engine = c.engine,
        .binary_mtime = binary_mtime,
        .io = c.io,
        .project = if (project_state) |*p| p else null,
        .ratchet = c.ratchet,
    }, socket_path) catch |err| switch (err) {
        error.AlreadyRunning => return printAndExit(c.stderr, "kata daemon already running\n", exit_clean),
        else => return internalError(c.stderr, "serve", err),
    };

    return exit_clean;
}

fn runCheck(c: Command, target: []const u8) !u8 {
    if (!try c.engine.prewarmOrReport("kata", c.stderr)) return exit_internal_error;

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
    return facts.run(c.io, c.gpa, c.engine, target, c.stdout, c.stderr);
}

fn runQuery(c: Command, q: query.Options) !u8 {
    return switch (try query.run(c.io, c.gpa, c.engine.registry, q, c.stdout, c.stderr)) {
        .clean => exit_clean,
        .matches => exit_violations,
        .usage => exit_usage,
    };
}

fn runRuleTest(c: Command, dir: []const u8) !u8 {
    if (dir.len == 0) return printAndExit(c.stderr, "usage: kata test <rules-dir>\n", exit_usage);
    return switch (try harness.run(c.io, c.gpa, c.arena, dir, c.stdout, c.stderr)) {
        .pass => exit_clean,
        .failures => exit_violations,
        .invalid => exit_internal_error,
    };
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

fn resolveSocketPath(
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    if (environ.get(args_mod.env_socket)) |path| return path;
    if (environ.get(args_mod.env_runtime_dir)) |dir|
        return std.fmt.allocPrint(arena, "{s}/kata.sock", .{dir});
    return args_mod.fallback_socket_path;
}

pub const Options = one_shot.Options;

pub fn run(
    allocator: std.mem.Allocator,
    engine: *Engine,
    opts: Options,
) !u8 {
    return one_shot.run(allocator, engine, opts);
}

fn printAndExit(stderr: *std.Io.Writer, message: []const u8, code: u8) !u8 {
    return output.message(stderr, message, code);
}

fn printfAndExit(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype, code: u8) !u8 {
    return output.format(stderr, fmt, args, code);
}

fn internalError(stderr: *std.Io.Writer, context: []const u8, err: anyerror) !u8 {
    return output.internal(stderr, context, err, exit_internal_error);
}

fn die(stderr: *std.Io.Writer, context: []const u8, err: anyerror) u8 {
    _ = output.internal(stderr, context, err, exit_internal_error) catch {};
    return exit_internal_error;
}

fn resolveUserRulesDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const base = (try config.resolveConfigBase(arena, environ)) orelse return null;
    return try fs.config.userRulesPath(arena, base);
}

fn drainWarnings(stderr: *std.Io.Writer, rule_set: *const loader_mod.RuleSet) void {
    for (rule_set.warnings.items) |w| {
        stderr.print("kata: warning: {s} rule {s}/{s} overrides previous definition\n", .{
            @tagName(w.source), w.lang.toString(), w.id,
        }) catch return;
    }
    stderr.flush() catch {};
}

fn dieConfig(stderr: *std.Io.Writer, diag: config.Diagnostic, err: anyerror) u8 {
    if (diag.line > 0) {
        stderr.print("kata: rules.yaml: line {d}: {s}\n", .{ diag.line, config.errorMessage(err) }) catch {};
    } else {
        stderr.print("kata: rules.yaml: {s}\n", .{@errorName(err)}) catch {};
    }
    stderr.flush() catch {};
    return exit_internal_error;
}

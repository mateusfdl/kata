const std = @import("std");

const build_options = @import("build_options");

const fs = @import("fs.zig");
const lint = @import("engine");
const reports = @import("reports.zig");
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

const daemon = server.daemon;
const protocol = server.protocol;
const config = sources.config;
const context_mod = sources.context;
const loader_mod = sources.loader;

const io_buffer_size: usize = 8192;

const Command = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    resolver: *context_mod.Resolver,
    environ: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const CheckOptions = struct {
    target: []const u8,
    format: reports.Format = .pretty,
    baseline: ?[]const u8 = null,
    fix: check.FixLevel = .off,
    invalid_arg: ?[]const u8 = null,
    missing_value: ?[]const u8 = null,

    const flag_parser = args_mod.parser(&.{
        .{ .name = "baseline", .kind = .arg },
        .{ .name = "json", .kind = .boolean },
        .{ .name = "text", .kind = .boolean },
        .{ .name = "sarif", .kind = .boolean },
        .{ .name = "fix", .kind = .boolean },
        .{ .name = "fix-unsafe", .kind = .boolean },
    });

    pub fn parse(args: []const [:0]const u8) CheckOptions {
        const parsed = flag_parser.parse(args);
        const positionals = parsed.positionals();

        var opts: CheckOptions = .{ .target = "." };
        opts.baseline = parsed.flags.baseline;
        opts.format = reports.Format.lastFlag(parsed.flags.json, parsed.flags.text, parsed.flags.sarif);
        opts.fix = if (parsed.flags.@"fix-unsafe" > parsed.flags.fix) .unsafe else if (parsed.flags.fix != 0) .safe else .off;
        opts.missing_value = parsed.missing;
        if (positionals.len > 0) opts.target = positionals[0];
        opts.invalid_arg = parsed.unknown orelse if (positionals.len > 1) positionals[1] else null;

        return opts;
    }
};

pub const Subcommand = union(enum) {
    version,
    daemon: ?[]const u8,
    check: CheckOptions,
    facts: []const u8,
    rule_test: []const u8,
    query: query.Options,
    stop,
    new_rule,
    one_shot,
    unknown: []const u8,
    invalid_arg: []const u8,
    missing_value: []const u8,
};

const ConfiguredCommand = union(enum) {
    daemon: ?[]const u8,
    check: CheckOptions,
    facts: []const u8,
    one_shot: []const [:0]const u8,
};

pub fn parseSubcommand(args: []const [:0]const u8) Subcommand {
    if (args.len == 0) return .{ .daemon = null };

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "--version")) return .version;
    if (args_mod.Spec.isFlag(cmd)) return .one_shot;

    return switch (std.meta.stringToEnum(args_mod.CommandName, cmd) orelse return .{ .unknown = cmd }) {
        .daemon => switch (DaemonArgs.parse(args[1..])) {
            .root => |root| .{ .daemon = root },
            .invalid => |arg| .{ .invalid_arg = arg },
            .missing_root_value => .{ .missing_value = "--root" },
        },
        .check => .{ .check = CheckOptions.parse(args[1..]) },
        .facts => facts: {
            const parsed = positional_parser.parse(args[1..]);
            if (parsed.unknown) |arg| break :facts .{ .invalid_arg = arg };
            const positionals = parsed.positionals();
            if (positionals.len == 0) break :facts .{ .facts = "" };
            if (positionals.len > 1) break :facts .{ .invalid_arg = positionals[1] };
            break :facts .{ .facts = positionals[0] };
        },
        .@"test" => rule_test: {
            const parsed = positional_parser.parse(args[1..]);
            if (parsed.unknown) |arg| break :rule_test .{ .invalid_arg = arg };
            const positionals = parsed.positionals();
            if (positionals.len == 0) break :rule_test .{ .rule_test = "" };
            if (positionals.len > 1) break :rule_test .{ .invalid_arg = positionals[1] };
            break :rule_test .{ .rule_test = positionals[0] };
        },
        .query => .{ .query = query.Options.parse(args[1..]) },
        .stop => if (args.len > 1) .{ .invalid_arg = args[1] } else .stop,
        .@"new-rule" => .new_rule,
    };
}

const positional_parser = args_mod.parser(&.{});

pub fn baselineRef(flag: ?[]const u8, environ: *std.process.Environ.Map) ?[]const u8 {
    return flag orelse environ.get(args_mod.env_baseline);
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [io_buffer_size]u8 = undefined;
    var stderr_buf: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const argv = init.minimal.args.toSlice(arena) catch |err| return die(stderr, "read args", err);
    const user_args = if (argv.len > 0) argv[1..] else argv;
    const subcommand = parseSubcommand(user_args);
    const configured: ConfiguredCommand = switch (subcommand) {
        .version => return runVersion(stdout) catch |err| die(stderr, "kata", err),
        .query => |opts| return runQuery(io, gpa, opts, stdout, stderr) catch |err| die(stderr, "kata", err),
        .stop => return runStop(io, arena, init.environ_map, stdout, stderr) catch |err| die(stderr, "kata", err),
        .rule_test => |dir| return runRuleTest(io, gpa, arena, dir, stdout, stderr) catch |err| die(stderr, "kata", err),
        .new_rule => {
            const user_dir = resolveUserRulesDir(arena, init.environ_map) catch |err|
                return die(stderr, "resolve user rules dir", err);
            return new_rule.run(arena, io, .{
                .args = user_args,
                .user_rules_dir = user_dir,
                .stdout = stdout,
                .stderr = stderr,
            }) catch |err| die(stderr, "new-rule", err);
        },
        .unknown => |cmd| return runUnknown(stderr, cmd) catch |err| die(stderr, "kata", err),
        .invalid_arg => |arg| return printfAndExit(stderr, "kata: unexpected argument \"{s}\"\n", .{arg}, exit.usage) catch |err|
            die(stderr, "kata", err),
        .missing_value => |flag| return printfAndExit(stderr, "kata: \"{s}\" requires a value\n", .{flag}, exit.usage) catch |err|
            die(stderr, "kata", err),
        .daemon => |root| .{ .daemon = root },
        .check => |opts| check: {
            if (opts.invalid_arg) |arg|
                return printfAndExit(stderr, "kata check: unexpected argument \"{s}\"\n", .{arg}, exit.usage) catch |err|
                    die(stderr, "kata", err);
            if (opts.missing_value) |flag|
                return printfAndExit(stderr, "kata check: \"{s}\" requires a value\n", .{flag}, exit.usage) catch |err|
                    die(stderr, "kata", err);
            break :check .{ .check = opts };
        },
        .facts => |target| facts_command: {
            if (target.len == 0)
                return printAndExit(stderr, "usage: kata facts <file>\n", exit.usage) catch |err| die(stderr, "kata", err);
            break :facts_command .{ .facts = target };
        },
        .one_shot => .{ .one_shot = user_args },
    };

    const user_dir = resolveUserRulesDir(arena, init.environ_map) catch |err| return die(stderr, "resolve user rules dir", err);
    var diag: config.Diagnostic = .{};
    var cfg = config.loadFromDisk(gpa, io, init.environ_map, &diag) catch |err| return dieConfig(stderr, diag, err);
    defer if (cfg) |*value| value.deinit();

    var resolver: context_mod.Resolver = .{
        .gpa = gpa,
        .io = io,
        .user_rules_dir = user_dir,
        .global_config = if (cfg) |*value| value else null,
    };

    return dispatchSubcommand(.{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .resolver = &resolver,
        .environ = init.environ_map,
        .stdout = stdout,
        .stderr = stderr,
    }, configured) catch |err| die(stderr, "kata", err);
}

fn runVersion(stdout: *std.Io.Writer) !u8 {
    try stdout.print("{s}\n", .{build_options.version});
    try stdout.flush();

    return exit.clean;
}

const DaemonArgs = union(enum) {
    root: ?[]const u8,
    invalid: []const u8,
    missing_root_value,

    const flag_parser = args_mod.parser(&.{
        .{ .name = "root", .kind = .arg },
    });

    pub fn parse(args: []const [:0]const u8) DaemonArgs {
        const parsed = flag_parser.parse(args);
        if (parsed.missing != null) return .missing_root_value;
        if (parsed.unknown) |arg| return .{ .invalid = arg };
        const positionals = parsed.positionals();
        if (positionals.len > 0) return .{ .invalid = positionals[0] };

        return .{ .root = parsed.flags.root };
    }
};

fn dispatchSubcommand(c: Command, subcommand: ConfiguredCommand) !u8 {
    return switch (subcommand) {
        .daemon => |root| runDaemon(c, root),
        .check => |opts| runCheck(c, opts),
        .facts => |target| runFacts(c, target),
        .one_shot => |args| runOneShot(c, args),
    };
}

fn resolveContext(c: Command, anchor: ?[]const u8) !?*context_mod.Context {
    const ctx = c.resolver.resolve(anchor) catch |err| {
        if (err == error.LifecycleCollision or err == error.RetiredRuleRemoved) {
            try c.resolver.rule_diag.write("kata", c.stderr);
            return null;
        }
        if (err == error.InvalidRetiredEntry or err == error.MissingRetiredReason) {
            try c.stderr.print("kata: retired.yaml: line {d}: {s}\n", .{
                c.resolver.retired_diag.line, sources.retired.errorMessage(err),
            });
            try c.stderr.flush();
            return null;
        }
        if (c.resolver.diag.line > 0) {
            try c.stderr.print("kata: .kata/rules.yaml: line {d}: {s}\n", .{ c.resolver.diag.line, config.errorMessage(err) });
            try c.stderr.flush();
            return null;
        }

        _ = try internalError(c.stderr, "resolve context", err);

        return null;
    };

    drainWarnings(c.stderr, &ctx.rule_set);

    return ctx;
}

fn runOneShot(c: Command, args: []const [:0]const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var stdin_buf: [io_buffer_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(c.io, &stdin_buf);

    const opts: one_shot.Options = .{
        .args = args,
        .stdin = &stdin_reader.interface,
        .stdout = c.stdout,
        .stderr = c.stderr,
    };
    const request = switch (try one_shot.prepare(a, opts)) {
        .ready => |r| r,
        .failed => |code| return code,
    };

    if (daemonReport(c, a, request)) |response| return one_shot.report(opts, response);

    const ctx = (try resolveContext(c, request.filename)) orelse return exit.internal_error;
    defer ctx.deinit();

    if (ctx.resolved.daemon_autostart) autostartDaemon(c);

    return one_shot.serve(.{
        .engine = &ctx.engine,
        .io = c.io,
        .ratchet = ctx.resolved.ratchet,
        .max_matches = ctx.resolved.max_matches_per_file,
        .cache_dir = if (ctx.resolved.cache) resolveCacheDir(c) else null,
        .cache_enabled = ctx.resolved.cache,
        .rules_hash = ctx.rules_hash,
    }, a, request, opts);
}

fn resolveCacheDir(c: Command) ?[]const u8 {
    return fs.result_cache.dir(c.arena, c.environ) catch null;
}

fn cacheHandle(c: Command, ctx: *const context_mod.Context) ?fs.result_cache.Handle {
    const dir = resolveCacheDir(c) orelse return null;

    return .{ .dir = dir, .rules_hash = ctx.rules_hash };
}

fn autostartDaemon(c: Command) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = fs.process.selfPath(c.io, &buf) catch return;

    fs.process.spawnDetached(c.io, &.{ self_path, "daemon" });
}

fn daemonReport(c: Command, arena: std.mem.Allocator, request: protocol.Request) ?protocol.Response {
    const socket_path = resolveSocketPath(c.io, c.arena, c.environ) catch return null;

    return server.client.request(c.io, arena, socket_path, request);
}

fn runUnknown(stderr: *std.Io.Writer, cmd: []const u8) !u8 {
    try stderr.print("unknown subcommand: \"{s}\"\n", .{cmd});
    try stderr.writeAll("usage: kata [daemon [--root <dir>] | check <path> | facts <file> | test <rules-dir> | query <rule> [path] --lang=<lang> | stop | new-rule <lang> <id> | --lang=<ts|tsx|go>]\n");
    try stderr.flush();
    return exit.usage;
}

fn runDaemon(c: Command, root: ?[]const u8) !u8 {
    const ctx = (try resolveContext(c, null)) orelse return exit.internal_error;
    defer ctx.deinit();

    if (!try ctx.engine.prewarmOrReport("kata", c.stderr)) return exit.internal_error;

    const socket_path = resolveSocketPath(c.io, c.arena, c.environ) catch |err|
        return internalError(c.stderr, "resolve socket path", err);

    var project_state: ?lint.Project = null;
    defer if (project_state) |*p| p.deinit();

    if (root) |r| {
        if (ctx.resolved.project_rules.len == 0 and ctx.engine.factRules().len == 0)
            return printAndExit(c.stderr, "kata daemon --root requires project rules in rules.yaml or rules/project\n", exit.usage);

        project_state = lint.Project.init(c.gpa, &ctx.engine, ctx.resolved.project_rules) catch |err|
            return internalError(c.stderr, "initialize project analysis", err);
        _ = daemon.buildIndex(c.io, c.gpa, r, &project_state.?) catch |err|
            return internalError(c.stderr, "index project", err);
    }

    var cache = context_mod.Cache.init(c.gpa, c.resolver);
    defer cache.deinit();

    daemon.serve(c.gpa, .{
        .engine = &ctx.engine,
        .io = c.io,
        .project = if (project_state) |*p| p else null,
        .ratchet = ctx.resolved.ratchet,
        .cache = &cache,
        .replay = &ctx.replay,
        .max_matches = ctx.resolved.max_matches_per_file,
        .cache_dir = if (ctx.resolved.cache) resolveCacheDir(c) else null,
        .cache_enabled = ctx.resolved.cache,
        .rules_hash = ctx.rules_hash,
    }, socket_path) catch |err| switch (err) {
        error.AlreadyRunning => return printAndExit(c.stderr, "kata daemon already running\n", exit.clean),
        else => return internalError(c.stderr, "serve", err),
    };

    return exit.clean;
}

fn runCheck(c: Command, opts: CheckOptions) !u8 {
    const ctx = (try resolveContext(c, opts.target)) orelse return exit.internal_error;

    defer ctx.deinit();
    if (!try ctx.engine.prewarmOrReport("kata", c.stderr)) return exit.internal_error;

    var baseline: ?check.Baseline = null;
    if (baselineRef(opts.baseline, c.environ)) |ref| {
        const dir = std.Io.Dir.cwd();
        fs.git.verifyRef(c.io, c.gpa, dir, ref) catch |err| switch (err) {
            error.UnknownRef => return printfAndExit(c.stderr, "unknown baseline ref \"{s}\"\n", .{ref}, exit.usage),
            error.NotAWorkTree => return printAndExit(c.stderr, "kata check --baseline requires a git work tree\n", exit.usage),
            else => return internalError(c.stderr, "verify baseline ref", err),
        };
        const prefix = fs.git.repoPrefix(c.io, c.arena, dir) catch |err| switch (err) {
            error.NotAWorkTree => return printAndExit(c.stderr, "kata check --baseline requires a git work tree\n", exit.usage),
            else => return internalError(c.stderr, "resolve repo prefix", err),
        };
        const backdated = check.backdatedRules(c.io, c.arena, .{
            .ref = ref,
            .prefix = prefix,
            .dir = dir,
        }, ctx.root, &ctx.rule_set) catch |err|
            return internalError(c.stderr, "baseline config", err);
        baseline = .{ .ref = ref, .prefix = prefix, .dir = dir, .backdated = backdated };
    }

    const color = opts.format == .pretty and (std.Io.File.stdout().supportsAnsiEscapeCodes(c.io) catch false);
    var reporter = reports.Reporter.init(c.gpa, opts.format, c.stdout, color);
    defer reporter.deinit();

    const fixing: ?check.Fixing = if (opts.fix == .off) null else .{ .level = opts.fix, .stderr = c.stderr };

    const outcome = check.run(c.io, c.gpa, &ctx.engine, .{
        .target = opts.target,
        .project_rules = ctx.resolved.project_rules,
        .max_matches = ctx.resolved.max_matches_per_file,
        .baseline = baseline,
        .fixing = fixing,
        .cache = if (ctx.resolved.cache) cacheHandle(c, ctx) else null,
    }, &reporter) catch |err| switch (err) {
        error.UnsupportedTarget => return printfAndExit(c.stderr, "cannot infer language from \"{s}\"\n", .{opts.target}, exit.usage),
        else => return internalError(c.stderr, "check", err),
    };

    return switch (outcome) {
        .clean => exit.clean,
        .violations => exit.violations,
    };
}

fn runFacts(c: Command, target: []const u8) !u8 {
    const ctx = (try resolveContext(c, target)) orelse return exit.internal_error;
    defer ctx.deinit();

    return facts.run(c.io, c.gpa, &ctx.engine, target, c.stdout, c.stderr);
}

fn runQuery(
    io: std.Io,
    gpa: std.mem.Allocator,
    q: query.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var opts = q;
    opts.color = opts.format == .pretty and (std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false);

    return switch (try query.run(io, gpa, opts, stdout, stderr)) {
        .clean => exit.clean,
        .matches => exit.violations,
        .usage => exit.usage,
    };
}

fn runRuleTest(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    dir: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (dir.len == 0) return printAndExit(stderr, "usage: kata test <rules-dir>\n", exit.usage);

    return switch (try harness.run(io, gpa, arena, dir, stdout, stderr)) {
        .pass => exit.clean,
        .failures => exit.violations,
        .invalid => exit.internal_error,
    };
}

fn runStop(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const socket_path = resolveSocketPath(io, arena, environ) catch |err|
        return internalError(stderr, "resolve socket path", err);

    if (server.client.request(io, arena, socket_path, .{ .shutdown = true }) == null)
        return printAndExit(stderr, "no kata daemon running\n", exit.clean);

    try stdout.writeAll("kata daemon stopped\n");
    try stdout.flush();

    return exit.clean;
}

pub fn socketPath(
    arena: std.mem.Allocator,
    runtime_dir: ?[]const u8,
    binary_mtime: i64,
) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/kata-{s}-{d}.sock", .{
        runtime_dir orelse "/tmp",
        build_options.version,
        binary_mtime,
    });
}

fn resolveSocketPath(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    if (environ.get(args_mod.env_socket)) |override| return override;

    const binary_mtime = try daemon.binaryMtime(io);

    return socketPath(
        arena,
        environ.get(args_mod.env_runtime_dir),
        binary_mtime,
    );
}

fn printAndExit(stderr: *std.Io.Writer, message: []const u8, code: u8) !u8 {
    return output.message(stderr, message, code);
}

fn printfAndExit(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype, code: u8) !u8 {
    return output.format(stderr, fmt, args, code);
}

fn internalError(stderr: *std.Io.Writer, context: []const u8, err: anyerror) !u8 {
    return output.internal(stderr, context, err, exit.internal_error);
}

fn die(stderr: *std.Io.Writer, context: []const u8, err: anyerror) u8 {
    _ = output.internal(stderr, context, err, exit.internal_error) catch {};

    return exit.internal_error;
}

fn resolveUserRulesDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const base = (try config.resolveConfigBase(arena, environ)) orelse return null;
    return try fs.config.userRulesPath(arena, base);
}

fn drainWarnings(stderr: *std.Io.Writer, rule_set: *const loader_mod.RuleSet) void {
    for (rule_set.warnings.items) |w| {
        const scope = if (w.lang) |lang| lang.toString() else "project";
        switch (w.kind) {
            .override => stderr.print("kata: warning: {s} rule {s}/{s} overrides previous definition\n", .{
                @tagName(w.source.?), scope, w.id,
            }) catch return,
            .renamed => stderr.print("kata: warning: rule id '{s}' was renamed to '{s}'; update rules.yaml\n", .{
                w.id, w.canonical.?,
            }) catch return,
            .experimental => stderr.print("kata: warning: rule {s}/{s} is experimental; set 'enabled: true' to activate it\n", .{
                scope, w.id,
            }) catch return,
            .deprecated => stderr.print("kata: warning: rule {s}/{s} is deprecated\n", .{
                scope, w.id,
            }) catch return,
        }
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

    return exit.internal_error;
}

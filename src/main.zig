const std = @import("std");

const cli = @import("cli.zig");
const lint = @import("lint.zig");
const sources = @import("sources.zig");
const new_rule = @import("cli/new_rule.zig");

const Engine = lint.Engine;
const language = lint.language;
const config = sources.config;
const loader_mod = sources.loader;

const io_buffer_size: usize = 8192;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (scope == .mvzr) return;
    std.log.defaultLog(level, scope, fmt, args);
}

pub fn main(init: std.process.Init) !void {
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

    const argv = try init.minimal.args.toSlice(arena);
    const user_args = if (argv.len > 0) argv[1..] else argv;

    const user_dir = resolveUserRulesDir(arena, init.environ_map) catch |err| die(stderr, "resolve user rules dir", err);

    if (user_args.len > 0 and std.mem.eql(u8, user_args[0], "new-rule")) {
        const code = new_rule.run(arena, io, .{
            .args = user_args,
            .user_rules_dir = user_dir,
            .stdout = &stdout_writer.interface,
            .stderr = stderr,
        }) catch |err| die(stderr, "new-rule", err);
        std.process.exit(code);
    }

    var registry = language.Registry.init();

    var rule_set = loader_mod.load(arena, io, .{
        .external_dir = init.environ_map.get("KATA_RULES_DIR"),
        .user_dir = user_dir,
    }) catch |err| die(stderr, "load rules", err);
    defer rule_set.deinit();

    drainWarnings(stderr, &rule_set);

    var diag: config.Diagnostic = .{};
    var cfg_opt = config.loadFromDisk(gpa, io, init.environ_map, &diag) catch |err| dieConfig(stderr, diag, err);
    defer if (cfg_opt) |*cfg| cfg.deinit();
    if (cfg_opt) |cfg| config.filterDisabled(&rule_set, cfg);

    var engine = Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();
    if (cfg_opt) |cfg| engine.metrics = cfg.metrics;

    const code = cli.dispatch(.{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .engine = &engine,
        .environ = init.environ_map,
        .args = user_args,
        .project_rules = if (cfg_opt) |cfg| cfg.project_rules else &.{},
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = stderr,
    }) catch |err| die(stderr, "kata", err);

    std.process.exit(code);
}

fn die(stderr: *std.Io.Writer, context: []const u8, err: anyerror) noreturn {
    stderr.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr.flush() catch {};
    std.process.exit(cli.exit_internal_error);
}

fn resolveUserRulesDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const base = (try config.resolveConfigBase(arena, environ)) orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/rules", .{base});
}

fn drainWarnings(stderr: *std.Io.Writer, rule_set: *const loader_mod.RuleSet) void {
    for (rule_set.warnings.items) |w| {
        stderr.print("kata: warning: {s} rule {s}/{s} overrides previous definition\n", .{
            @tagName(w.source), w.lang.toString(), w.id,
        }) catch return;
    }
    stderr.flush() catch {};
}

fn dieConfig(stderr: *std.Io.Writer, diag: config.Diagnostic, err: anyerror) noreturn {
    if (diag.line > 0) {
        stderr.print("kata: rules.yaml: line {d}: {s}\n", .{ diag.line, config.errorMessage(err) }) catch {};
    } else {
        stderr.print("kata: rules.yaml: {s}\n", .{@errorName(err)}) catch {};
    }
    stderr.flush() catch {};
    std.process.exit(cli.exit_internal_error);
}

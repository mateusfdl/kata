const std = @import("std");

const cli = @import("cli.zig");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const loader_mod = @import("loader.zig");
const new_rule = @import("new_rule.zig");
const stats = @import("stats.zig");

const io_buffer_size: usize = 8192;

pub fn main(init: std.process.Init) !void {
    const stats_enabled = init.environ_map.get("KATA_STATS") != null;
    var counting: stats.Counting = .{ .child = init.gpa };
    const gpa = if (stats_enabled) counting.allocator() else init.gpa;
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
    defer registry.deinit();

    var rule_set = loader_mod.load(arena, io, .{
        .external_dir = init.environ_map.get("KATA_RULES_DIR"),
        .user_dir = user_dir,
    }) catch |err| die(stderr, "load rules", err);
    defer rule_set.deinit();

    drainWarnings(stderr, &rule_set);

    var diag: config.Diagnostic = .{};
    var cfg_opt = config.loadFromDisk(gpa, io, init.environ_map, &diag) catch |err| dieConfig(stderr, diag, err);
    if (cfg_opt) |*cfg| {
        defer cfg.deinit();
        config.filterDisabled(&rule_set, cfg.*);
    }

    var engine = engine_mod.Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();

    const code = cli.dispatch(.{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .engine = &engine,
        .environ = init.environ_map,
        .args = user_args,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = stderr,
    }) catch |err| die(stderr, "kata", err);

    if (stats_enabled) counting.report(stderr) catch {};
    std.process.exit(code);
}

fn die(stderr: *std.Io.Writer, context: []const u8, err: anyerror) noreturn {
    stderr.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr.flush() catch {};
    std.process.exit(cli.exit_internal_error);
}

fn resolveUserRulesDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(arena, "{s}/kata/rules", .{xdg});
    }
    if (environ.get("HOME")) |home| {
        return try std.fmt.allocPrint(arena, "{s}/.config/kata/rules", .{home});
    }
    return null;
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

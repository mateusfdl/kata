const std = @import("std");

const cli = @import("cli.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const loader_mod = @import("loader.zig");
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

    var registry = language.Registry.init();
    defer registry.deinit();

    var rule_set = loader_mod.load(arena, io, .{
        .external_dir = init.environ_map.get("KATA_RULES_DIR"),
    }) catch |err| die(stderr, "load rules", err);
    defer rule_set.deinit();

    var engine = engine_mod.Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();

    const argv = try init.minimal.args.toSlice(arena);
    const user_args = if (argv.len > 0) argv[1..] else argv;

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

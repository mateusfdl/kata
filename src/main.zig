const std = @import("std");

const cli = @import("cli.zig");
const engine_mod = @import("engine.zig");
const language = @import("language.zig");
const loader_mod = @import("loader.zig");

const stdin_buffer_size: usize = 8192;
const stdout_buffer_size: usize = 8192;
const stderr_buffer_size: usize = 512;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena_alloc = init.arena.allocator();
    const io = init.io;

    var registry = language.Registry.init();
    defer registry.deinit();

    const rules_dir = init.environ_map.get("KATA_RULES_DIR");

    var rule_set = loader_mod.load(arena_alloc, io, .{ .external_dir = rules_dir }) catch |err|
        fatal(io, "kata: load rules", err);
    defer rule_set.deinit();

    var engine = engine_mod.Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();

    const argv = try init.minimal.args.toSlice(arena_alloc);
    const user_args = if (argv.len > 0) argv[1..] else argv;

    var stdin_buf: [stdin_buffer_size]u8 = undefined;
    var stdout_buf: [stdout_buffer_size]u8 = undefined;
    var stderr_buf: [stderr_buffer_size]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);

    const code = cli.run(gpa, &engine, .{
        .args = user_args,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    }) catch |err| {
        stderr_writer.interface.print("kata: {s}\n", .{@errorName(err)}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(cli.exit_internal_error);
    };

    std.process.exit(code);
}

fn fatal(io: std.Io, context: []const u8, err: anyerror) noreturn {
    var buf: [stderr_buffer_size]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &buf);
    stderr_w.interface.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr_w.interface.flush() catch {};
    std.process.exit(cli.exit_internal_error);
}

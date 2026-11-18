const std = @import("std");

const build_options = @import("build_options");

const args = @import("cli/args.zig");
const check = @import("cli/check.zig");
const daemon = @import("cli/daemon.zig");
const facts = @import("cli/facts.zig");
const harness = @import("cli/harness.zig");
const new_rule = @import("cli/new_rule.zig");
const one_shot = @import("cli/one_shot.zig");
const output = @import("cli/output.zig");
const query = @import("cli/query.zig");
const stop = @import("cli/stop.zig");

const Env = @import("cli/env.zig").Env;
const Exit = @import("cli/exit.zig").Exit;

const io_buffer_size: usize = 8192;

/// Every subcommand. A command is a module with `name`, `synopsis`, `grammar`
/// and `execute(env, args)`; this list is the only place that names them all.
const commands = .{ daemon, check, facts, harness, query, stop, new_rule };

const usage = blk: {
    var text: []const u8 = "";
    for (commands) |command| text = text ++ usageLine(command);

    break :blk text ++ usageLine(one_shot);
};

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdin_buf: [io_buffer_size]u8 = undefined;
    var stdout_buf: [io_buffer_size]u8 = undefined;
    var stderr_buf: [io_buffer_size]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);

    const env: Env = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
        .color = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false,
    };

    const argv = init.minimal.args.toSlice(arena) catch |err| return @intFromEnum(unexplained(env.stderr, "read args", err));
    const user_args = if (argv.len > 0) argv[1..] else argv;

    const code = dispatch(env, user_args) catch |err| switch (err) {
        error.UsageReported => Exit.usage,
        error.InternalReported => Exit.internal_error,
        else => unexplained(env.stderr, "kata", err),
    };

    return @intFromEnum(code);
}

pub fn dispatch(env: Env, argv: []const [:0]const u8) !Exit {
    if (argv.len == 0) return invoke(daemon, "kata " ++ daemon.name, env, argv);

    const first = argv[0];
    if (std.mem.eql(u8, first, "--version")) {
        try env.stdout.print("{s}\n", .{build_options.version});
        try env.stdout.flush();

        return .clean;
    }
    if (args.isFlag(first)) return invoke(one_shot, "kata", env, argv);

    inline for (commands) |command| {
        if (std.mem.eql(u8, first, command.name)) return invoke(command, "kata " ++ command.name, env, argv[1..]);
    }

    return output.usage(env.stderr, "unknown subcommand: \"{s}\"\n" ++ usage, .{first});
}

fn invoke(comptime command: type, comptime label: []const u8, env: Env, argv: []const [:0]const u8) !Exit {
    const invalid = switch (command.grammar.parse(argv)) {
        .ok => |parsed| return command.execute(env, parsed),
        .invalid => |invalid| invalid,
    };

    return switch (invalid) {
        .unexpected => |arg| output.usage(env.stderr, label ++ ": unexpected argument \"{s}\"\n" ++ usageLine(command), .{arg}),
        .missing_value => |flag| output.usage(env.stderr, label ++ ": \"{s}\" requires a value\n" ++ usageLine(command), .{flag}),
        .missing_positional => output.usage(env.stderr, usageLine(command), .{}),
    };
}

fn usageLine(comptime command: type) []const u8 {
    return "usage: kata " ++ command.synopsis ++ "\n";
}

// An error that nothing explained on the way up. The message can fail to
// reach a closed stderr; the exit code still tells the caller.
fn unexplained(stderr: *std.Io.Writer, context: []const u8, err: anyerror) Exit {
    stderr.print("{s}: {s}\n", .{ context, @errorName(err) }) catch {};
    stderr.flush() catch {};

    return .internal_error;
}

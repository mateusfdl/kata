const std = @import("std");

const cli = @import("cli");
const endpoint = @import("daemon_endpoint.zig");
const lint = @import("engine");
const output = @import("output.zig");
const server = @import("../server.zig");

const Workspace = @import("workspace.zig").Workspace;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const language = lint.language;
const linting = server.linting;

pub const Args = struct {
    lang: ?[]const u8 = null,
    filename: ?[]const u8 = null,
};

pub const command = cli.command(Args, .{
    .name = "",
    .flags = .{
        .{ .name = "lang", .field = .lang, .label = "<" ++ language.pipe_list ++ ">" },
        .{ .name = "filename", .field = .filename, .label = "<path>" },
    },
    .stdin = "source",
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    const input = try readInput(env, parsed);

    if (daemonReport(env, input)) |rendered| return report(env, rendered);

    var workspace = try Workspace.open(env, input.filename);
    defer workspace.deinit();
    const ctx = workspace.ctx;

    if (ctx.resolved.daemon_autostart) endpoint.autostart(env);

    return lintLocally(env, try workspace.lintContext(env), input);
}

pub fn readInput(env: Env, parsed: Args) !linting.Input {
    const lang_flag = parsed.lang orelse "";
    const filename = parsed.filename orelse "";

    const lang = switch (language.resolve(lang_flag, filename)) {
        .ok => |n| n,
        .missing => return output.usage(env.stderr, "missing --lang (or provide --filename with a known extension)\n", .{}),
        .unknown_extension => |ext| return output.usage(env.stderr, "cannot infer language from extension \"{s}\"\n", .{ext}),
        .unsupported_language => |unsupported| return output.failure(env.stderr, "lint: unsupported language: \"{s}\"\n", .{unsupported}),
    };

    const source = env.stdin.allocRemaining(env.arena, .unlimited) catch |err|
        return output.internal(env.stderr, "read stdin", err);

    return .{
        .language = lang,
        // an empty --filename= means that the source has no file.
        .filename = if (filename.len > 0) filename else null,
        .source = source,
    };
}

/// Lint without a daemon, through the same pipeline that the daemon runs.
pub fn lintLocally(env: Env, ctx: linting.Context, input: linting.Input) !Exit {
    if (!try ctx.policy.engine.prewarmOrReport("kata", env.stderr)) return error.InternalReported;

    const rendered = linting.run(ctx, env.arena, input) catch |err|
        return output.failure(env.stderr, "kata: {s}\n", .{linting.failureMessage(err)});
    return report(env, rendered);
}

fn report(env: Env, rendered: lint.diagnostic.Report) !Exit {
    writeReport(env.stdout, rendered) catch |err|
        return output.internal(env.stderr, "encode report", err);

    return if (rendered.clean) .clean else .violations;
}

fn writeReport(stdout: *std.Io.Writer, rendered: lint.diagnostic.Report) !void {
    try std.json.Stringify.value(rendered, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
}

// A daemon that cannot be reached is not a failure: the caller lints locally.
fn daemonReport(env: Env, input: linting.Input) ?lint.diagnostic.Report {
    const socket_path = endpoint.socketPath(env) catch return null;

    return server.client.lint(env.io, env.arena, socket_path, input);
}

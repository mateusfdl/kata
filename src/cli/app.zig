const build_options = @import("build_options");
const cli = @import("cli");

const check = @import("check.zig");
const daemon = @import("daemon.zig");
const facts = @import("facts.zig");
const test_rules = @import("test_rules.zig");
const lint_stdin = @import("lint_stdin.zig");
const new_rule = @import("new_rule.zig");
const query = @import("query.zig");
const stop = @import("stop.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const app = cli.app(Exit, .{
    .name = "kata",
    .help_result = Exit.clean,
    .commands = .{
        daemon.command,
        check.command,
        facts.command,
        test_rules.command,
        query.command,
        stop.command,
        new_rule.command,
    },
    .default = daemon.command,
    .root = lint_stdin.command,
    .leading_flags = .{
        .{ .name = "version", .run = printVersion },
    },
});

pub fn dispatch(env: Env, argv: []const [:0]const u8) !Exit {
    return app.dispatch(env, env.stdout, env.stderr, argv);
}

fn printVersion(env: Env) !Exit {
    try env.stdout.writeAll(build_options.version ++ "\n");
    try env.stdout.flush();

    return .clean;
}

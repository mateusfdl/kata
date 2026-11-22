const std = @import("std");

const cli = @import("cli");
const endpoint = @import("daemon_endpoint.zig");
const lint = @import("engine");
const output = @import("output.zig");
const server = @import("../server.zig");
const sources = @import("../sources.zig");

const LintSetup = @import("lint_setup.zig").LintSetup;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

pub const Args = struct {
    root: ?[]const u8 = null,
};

pub const command = cli.command(Args, .{
    .name = endpoint.command,
    .flags = .{
        .{ .name = "root", .field = .root, .label = "<dir>" },
    },
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    var lint_setup = try LintSetup.load(env, parsed.root);
    defer lint_setup.deinit();

    const ctx = lint_setup.ctx;

    if (!try ctx.engine.prewarmOrReport("kata", env.stderr)) {
        return error.InternalReported;
    }

    const socket_path = endpoint.socketPath(env) catch |err| {
        return output.internal(env.stderr, "resolve socket path", err);
    };

    var project: ?lint.Project = if (parsed.root) |root| try indexProject(env, ctx, root) else null;
    defer if (project) |*p| p.deinit();

    var cache = server.context_cache.Cache.init(env.gpa, &lint_setup.resolver);
    defer cache.deinit();

    var diagnostics_cache = server.file_diagnostics_cache.FileDiagnosticsCache.init(env.gpa, server.file_diagnostics_cache.default_capacity) catch |err| {
        return output.internal(env.stderr, "initialize file diagnostics cache", err);
    };

    defer diagnostics_cache.deinit();

    var lint_context = try lint_setup.lintContext(env);

    lint_context.project = if (project) |*p| p else null;
    lint_context.cache = &cache;
    lint_context.diagnostics_cache = &diagnostics_cache;

    server.daemon.serve(env.gpa, lint_context, socket_path) catch |err| switch (err) {
        error.AlreadyRunning => {
            try env.stderr.writeAll("kata daemon already running\n");
            try env.stderr.flush();
        },
        else => return output.internal(env.stderr, "serve", err),
    };

    return .clean;
}

fn indexProject(env: Env, ctx: *sources.context.Context, root: []const u8) !lint.Project {
    var project = lint.Project.init(env.gpa, &ctx.engine, ctx.resolved.project_rules) catch |err| {
        return output.internal(env.stderr, "initialize project analysis", err);
    };
    errdefer project.deinit();

    if (!project.hasCrossFileRules())
        return output.usage(env.stderr, "kata daemon --root requires project rules in rules.yaml or rules/project\n", .{});

    _ = server.daemon.buildIndex(env.io, env.gpa, root, &project) catch |err|
        return output.internal(env.stderr, "index project", err);

    return project;
}

const std = @import("std");

const args = @import("args.zig");
const endpoint = @import("daemon_endpoint.zig");
const lint = @import("engine");
const output = @import("output.zig");
const server = @import("../server.zig");
const sources = @import("../sources.zig");

const Workspace = @import("workspace.zig").Workspace;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

pub const name = endpoint.command;
pub const synopsis = "daemon [--root <dir>]";

pub const Args = struct {
    root: ?[]const u8 = null,
};

pub const grammar = args.grammar(Args, .{
    .flags = .{.{ .name = "root", .field = .root }},
    .positionals = .{},
});

pub fn execute(env: Env, parsed: Args) !Exit {
    var workspace = try Workspace.open(env, parsed.root);
    defer workspace.deinit();
    const ctx = workspace.ctx;

    if (!try ctx.engine.prewarmOrReport("kata", env.stderr)) return error.InternalReported;

    const socket_path = endpoint.socketPath(env) catch |err|
        return output.internal(env.stderr, "resolve socket path", err);

    var project: ?lint.Project = if (parsed.root) |root| try indexProject(env, ctx, root) else null;
    defer if (project) |*p| p.deinit();

    var cache = server.context_cache.Cache.init(env.gpa, &workspace.resolver);
    defer cache.deinit();

    var replay_cache = server.replay.ReplayCache.init(env.gpa, server.replay.default_capacity) catch |err|
        return output.internal(env.stderr, "initialize replay cache", err);
    defer replay_cache.deinit();

    var lint_context = try workspace.lintContext(env);
    lint_context.project = if (project) |*p| p else null;
    lint_context.cache = &cache;
    lint_context.replay = &replay_cache;

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
    var project = lint.Project.init(env.gpa, &ctx.engine, ctx.resolved.project_rules) catch |err|
        return output.internal(env.stderr, "initialize project analysis", err);
    errdefer project.deinit();

    if (!project.hasCrossFileRules())
        return output.usage(env.stderr, "kata daemon --root requires project rules in rules.yaml or rules/project\n", .{});

    _ = server.daemon.buildIndex(env.io, env.gpa, root, &project) catch |err|
        return output.internal(env.stderr, "index project", err);

    return project;
}

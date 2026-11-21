const std = @import("std");

const fs = @import("../fs.zig");
const output = @import("output.zig");
const sources = @import("../sources.zig");
const server = @import("../server.zig");

const Env = @import("env.zig").Env;

const config = sources.config;
const context = sources.context;

/// The rules that apply to one invocation: the global config, and the context
/// of the project that owns `start_path`.
pub const Workspace = struct {
    global: ?*config.Config,
    resolver: context.Resolver,
    ctx: *context.Context,

    pub fn open(env: Env, start_path: ?[]const u8) !Workspace {
        const global = try loadGlobal(env);
        errdefer if (global) |g| g.deinit();

        var resolver: context.Resolver = .{
            .gpa = env.gpa,
            .io = env.io,
            .user_rules_dir = try fs.config.resolveUserRules(env.arena, env.environ),
            .global_config = global,
        };

        const ctx = resolver.resolve(start_path) catch |err| {
            // the resolver records a line only when the project rules.yaml does not parse.
            if (resolver.diag.line > 0)
                return output.failure(env.stderr, "kata: .kata/rules.yaml: line {d}: {s}\n", .{ resolver.diag.line, config.errorMessage(err) });

            return output.internal(env.stderr, "resolve context", err);
        };
        errdefer ctx.deinit();

        try warnOverrides(env.stderr, &ctx.rule_set);

        return .{ .global = global, .resolver = resolver, .ctx = ctx };
    }

    pub fn deinit(self: *Workspace) void {
        self.ctx.deinit();
        if (self.global) |global| global.deinit();
    }

    /// Resolves the cache location independently of global enablement: a daemon
    /// request can select a project whose configuration enables caching.
    pub fn lintContext(self: *Workspace, env: Env) !server.linting.Context {
        return .{
            .policy = self.ctx.policy(),
            .io = env.io,
            .cache_dir = try fs.result_cache.dir(env.arena, env.environ),
        };
    }
};

// The resolver keeps a pointer to the global config, so the config lives in
// the arena and the workspace can move.
fn loadGlobal(env: Env) !?*config.Config {
    var diag: config.Diagnostic = .{};
    var loaded = config.loadFromDisk(env.gpa, env.io, env.environ, &diag) catch |err| {
        if (diag.line > 0)
            return output.failure(env.stderr, "kata: rules.yaml: line {d}: {s}\n", .{ diag.line, config.errorMessage(err) });

        return output.failure(env.stderr, "kata: rules.yaml: {s}\n", .{@errorName(err)});
    } orelse return null;
    errdefer loaded.deinit();

    const global = try env.arena.create(config.Config);
    global.* = loaded;

    return global;
}

fn warnOverrides(stderr: *std.Io.Writer, rule_set: *const sources.loader.RuleSet) !void {
    for (rule_set.warnings.items) |warning| {
        const scope = if (warning.lang) |lang| lang.toString() else "project";
        try stderr.print("kata: warning: {s} rule {s}/{s} overrides previous definition\n", .{
            @tagName(warning.source.?), scope, warning.id,
        });
    }

    try stderr.flush();
}

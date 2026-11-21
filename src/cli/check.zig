const std = @import("std");

const analysis = @import("analysis.zig");
const cli = @import("cli");
const fs = @import("../fs.zig");
const lint = @import("engine");
const output = @import("output.zig");
const report_flags = @import("report_flags.zig");
const reports = @import("../reports.zig");
const sources = @import("../sources.zig");

const Workspace = @import("workspace.zig").Workspace;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const Engine = lint.Engine;

const Baseline = @import("baseline.zig").Baseline;

const env_baseline = "KATA_BASELINE";

pub const Args = struct {
    target: []const u8 = ".",
    format: reports.Format = .pretty,
    baseline: ?[]const u8 = null,
    fix: ?Engine.FixPolicy = null,
};

pub const command = cli.command(Args, .{
    .name = "check",
    .positionals = .{
        .{ .field = .target, .label = "path" },
    },
    .flags = report_flags.format ++ .{
        .{ .name = "fix", .field = .fix, .value = .safe },
        .{ .name = "fix-unsafe", .field = .fix, .value = .unsafe },
        .{ .name = "baseline", .field = .baseline, .label = "<ref>" },
    },
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    var workspace = try Workspace.open(env, parsed.target);
    defer workspace.deinit();
    const ctx = workspace.ctx;

    const baseline_ref = parsed.baseline orelse env.environ.get(env_baseline);

    return analysis.report(env, &ctx.engine, .{ .name = command.name, .rules_failure = error.InternalReported }, .{
        .target = parsed.target,
        .project_rules = ctx.resolved.project_rules,
        .max_matches = ctx.resolved.max_matches_per_file,
        .baseline = if (baseline_ref) |ref| try openBaseline(env, ctx, parsed.target, ref) else null,
        .fixing = if (parsed.fix) |policy| .{ .policy = policy, .stderr = env.stderr } else null,
        .cache = try cacheHandle(env, ctx),
    }, parsed.format);
}

fn openBaseline(env: Env, ctx: *const sources.context.Context, target: []const u8, ref: []const u8) !Baseline {
    return Baseline.open(env.io, env.gpa, env.arena, target, ref, ctx.root, &ctx.rule_set) catch |err| switch (err) {
        error.UnknownRef => output.usage(env.stderr, "unknown baseline ref \"{s}\"\n", .{ref}),
        error.NotAWorkTree => output.usage(env.stderr, "kata check --baseline requires a git work tree\n", .{}),
        else => output.internal(env.stderr, "baseline", err),
    };
}

/// Null when the configuration disables the cache or the environment names
/// no cache directory.
fn cacheHandle(env: Env, ctx: *const sources.context.Context) !?fs.result_cache.Handle {
    if (!ctx.resolved.cache) return null;

    const dir = (try fs.result_cache.dir(env.arena, env.environ)) orelse return null;

    return .{ .dir = dir, .rules_hash = ctx.rules_hash };
}

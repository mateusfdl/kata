const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const context_cache = @import("context_cache.zig");
const replay = @import("replay.zig");
const Policy = @import("../sources.zig").context.Policy;

const diagnostic = lint.diagnostic;
const language = lint.language;
const Engine = lint.Engine;

pub const Input = struct {
    language: language.Name,
    source: []const u8,
    filename: ?[]const u8 = null,
};

pub const Error = error{
    FixtureCheckFailed,
    ProjectContextFailed,
    ProjectConfigurationFailed,
    LintFailed,
    FingerprintFailed,
    RatchetFailed,
    ProjectAnalysisFailed,
    CapsFailed,
};

pub fn failureMessage(err: Error) []const u8 {
    return switch (err) {
        error.FixtureCheckFailed => "fixture check failed",
        error.ProjectContextFailed => "project context failed",
        error.ProjectConfigurationFailed => "project configuration failed",
        error.LintFailed => "lint failed",
        error.FingerprintFailed => "fingerprint failed",
        error.RatchetFailed => "ratchet baseline failed",
        error.ProjectAnalysisFailed => "project analysis failed",
        error.CapsFailed => "caps failed",
    };
}

pub const Context = struct {
    policy: Policy,
    io: std.Io,
    project: ?*lint.Project = null,
    cache: ?*context_cache.Cache = null,
    replay: ?*replay.ReplayCache = null,
    cache_dir: ?[]const u8 = null,

    fn select(self: Context, arena: std.mem.Allocator, filename: ?[]const u8) Error!Selection {
        if (self.cache) |cache| {
            // An index uses its root's policy for every file, including files
            // beneath a nested .kata directory. File-only requests select by path.
            const anchor = if (self.project != null) self.policy.root else filename;
            const entry = cache.acquire(arena, anchor) catch return error.ProjectContextFailed;
            if (entry) |p| return .{ .policy = p.ctx.policy(), .replay = &p.replay };
        }
        return .{ .policy = self.policy, .replay = self.replay };
    }
};

const Selection = struct {
    policy: Policy,
    replay: ?*replay.ReplayCache,
};

pub fn run(
    ctx: Context,
    arena: std.mem.Allocator,
    input: Input,
) Error!diagnostic.Report {
    const lang = input.language;
    const source = input.source;

    if (input.filename) |filename| {
        const is_fixture = fs.rules.isFixturePath(ctx.io, filename) catch
            return error.FixtureCheckFailed;
        if (is_fixture)
            return .{
                .language = lang.toString(),
                .diagnostics = &.{},
                .clean = true,
            };
    }

    const selected = try ctx.select(arena, input.filename);
    const engine = selected.policy.engine;
    const policy = selected.policy.resolved;

    const disk_cache: ?fs.result_cache.Entry = handle: {
        if (!policy.cache) break :handle null;
        if (ctx.project != null) break :handle null;
        const dir = ctx.cache_dir orelse break :handle null;
        const path = input.filename orelse break :handle null;
        const cache: fs.result_cache.Handle = .{ .dir = dir, .rules_hash = selected.policy.rules_hash };
        break :handle cache.entry(.{ .language = lang, .source = source, .path = path });
    };

    if (ctx.project) |project| {
        project.configure(engine, policy.project_rules) catch return error.ProjectConfigurationFailed;
    }

    const replay_generation: u64 = if (ctx.project) |p|
        (if (p.hasCrossFileRules()) p.indexGeneration() else 0)
    else
        0;

    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});

    const diagnostics = replayed: {
        if (selected.replay) |rc| {
            if (input.filename) |path| {
                // A generation-matched hit proves the index has not changed
                // since the entry was stored, so the file's facts are already
                // indexed for this exact content and re-indexing is redundant.
                if (rc.get(path, lang, content_hash, replay_generation)) |cached| {
                    break :replayed arena.dupe(diagnostic.Diagnostic, cached) catch
                        return error.LintFailed;
                }
            }
        }

        if (disk_cache) |cache| {
            if (cache.isClean(ctx.io))
                break :replayed arena.alloc(diagnostic.Diagnostic, 0) catch
                    return error.LintFailed;
        }

        const fresh = if (ctx.project) |project| lint: {
            const path = input.filename orelse break :lint engine.lint(arena, source, lang, null) catch
                return error.LintFailed;
            break :lint project.lint(arena, source, lang, path) catch
                return error.LintFailed;
        } else engine.lint(arena, source, lang, input.filename) catch
            return error.LintFailed;

        lint.fingerprint.assign(arena, input.filename orelse "", source, fresh) catch
            return error.FingerprintFailed;

        if (selected.replay) |rc| {
            // Replay is an optimization. Allocation failure must not turn a
            // successful lint into a failed request.
            const post_lint_generation: u64 = if (ctx.project) |p|
                (if (p.hasCrossFileRules()) p.indexGeneration() else 0)
            else
                0;
            if (input.filename) |path| rc.put(path, lang, content_hash, post_lint_generation, fresh) catch {};
        }

        if (disk_cache) |cache| {
            if (fresh.len == 0) cache.markClean(ctx.io);
        }

        break :replayed fresh;
    };

    applyRatchet(ctx, engine, policy.ratchet, arena, lang, input.filename, source, diagnostics) catch
        return error.RatchetFailed;

    const all = appendProjectDiagnostics(ctx, arena, input.filename, diagnostics) catch
        return error.ProjectAnalysisFailed;

    lint.fingerprint.assign(arena, input.filename orelse "", source, all) catch
        return error.FingerprintFailed;

    const rendered = lint.caps.apply(arena, all, engine.settings, policy.max_matches_per_file) catch
        return error.CapsFailed;

    return .{
        .language = lang.toString(),
        .diagnostics = rendered,
        .clean = !diagnostic.hasErrors(all),
    };
}

fn applyRatchet(
    ctx: Context,
    engine: *Engine,
    ratchet: bool,
    arena: std.mem.Allocator,
    lang: language.Name,
    filename: ?[]const u8,
    source: []const u8,
    diagnostics: []diagnostic.Diagnostic,
) !void {
    if (!ratchet) return;

    const io = ctx.io;
    const path = filename orelse return;

    if (!diagnostic.hasErrors(diagnostics)) return;

    const baseline_source = fs.source.read(io, arena, path) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return,
        else => return err,
    };

    const before = try engine.lint(arena, baseline_source, lang, path);
    try lint.fingerprint.assign(arena, path, baseline_source, before);
    _ = try lint.baseline.demote(arena, source, diagnostics, baseline_source, before);
}

fn appendProjectDiagnostics(
    ctx: Context,
    arena: std.mem.Allocator,
    filename: ?[]const u8,
    diagnostics: []diagnostic.Diagnostic,
) ![]diagnostic.Diagnostic {
    const project = ctx.project orelse return diagnostics;
    const path = filename orelse return diagnostics;

    const violations = try project.diagnostics(arena, path);
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    try out.appendSlice(arena, diagnostics);

    for (violations) |v| try out.append(arena, v.diagnostic);

    std.mem.sort(diagnostic.Diagnostic, out.items, {}, diagnostic.lessThan);

    return out.toOwnedSlice(arena);
}

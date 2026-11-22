const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const output = @import("output.zig");
const check_report = @import("check_report.zig");
const reports = @import("../reports.zig");
const sources = @import("../sources.zig");

const Baseline = @import("baseline.zig").Baseline;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;
const FileDiagnostics = @import("file_diagnostics.zig").FileDiagnostics;
const Engine = lint.Engine;
const language = lint.language;
const CheckReport = check_report.CheckReport;
const Diagnostic = lint.diagnostic.Diagnostic;

/// What differs between the commands that report on a target.
pub const Command = struct {
    name: []const u8,
    rules_failure: error{ UsageReported, InternalReported },
};

pub fn report(env: Env, engine: *Engine, command: Command, opts: Options, format: reports.Format) !Exit {
    if (!try engine.prewarmOrReport("kata", env.stderr)) return command.rules_failure;

    var reporter = reports.Reporter.init(env.gpa, format, env.stdout, env.color);
    defer reporter.deinit();

    return run(env.io, env.gpa, engine, opts, &reporter) catch |err| switch (err) {
        error.UnsupportedTarget => output.usage(env.stderr, "cannot infer language from \"{s}\"\n", .{opts.target}),
        else => output.internal(env.stderr, command.name, err),
    };
}

pub const Options = struct {
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule = &.{},
    max_matches: u32 = (sources.config.Resolved{}).max_matches_per_file,
    baseline: ?Baseline = null,
    fixing: ?Fixing = null,
    cache: ?fs.clean_file_cache.Handle = null,
};

pub const Fixing = struct {
    policy: Engine.FixPolicy,
    stderr: *std.Io.Writer,

    /// Applies the fixes of the policy to the file on disk and returns the
    /// diagnostics that remain in the fixed source.
    fn apply(
        fixing: Fixing,
        io: std.Io,
        arena: *std.heap.ArenaAllocator,
        project: *lint.Project,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !FileDiagnostics {
        const result = try project.engine.fix(arena, source, lang, path, fixing.policy);

        if (result.status == .syntax_error) {
            try fixing.stderr.print("kata check: fix for [{s}] introduces a syntax error in {s}\n", .{
                try std.mem.join(arena.allocator(), ", ", result.rule_ids),
                path,
            });
            try fixing.stderr.flush();
        }

        if (result.changed) try fs.source.write(io, path, result.source);
        const current = if (result.changed) result.source else source;

        try project.replace(current, lang, path);

        return FileDiagnostics.init(arena.allocator(), path, lang, current, result.diagnostics);
    }
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    opts: Options,
    reporter: *reports.Reporter,
) !Exit {
    const stat = try fs.source.statTarget(io, opts.target);

    var project = try lint.Project.init(gpa, engine, opts.project_rules);
    defer project.deinit();

    var shown: CheckReport = .init(gpa, reporter, engine.settings, opts.max_matches);
    defer shown.deinit();

    const files: FileCheck = .{
        .io = io,
        .gpa = gpa,
        .project = &project,
        .baseline = opts.baseline,
        .operation = Operation.prepare(opts, &project),
        .shown = &shown,
    };

    switch (stat.kind) {
        .directory => _ = try fs.source.walkFiles(io, gpa, opts.target, files, FileCheck.check),
        .file => try files.checkPath(opts.target),
        else => return error.UnsupportedTarget,
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    return if (try shown.finish(arena, try projectFiles(arena, io, &project))) .violations else .clean;
}

const Operation = union(enum) {
    /// The handle remembers which file contents had no diagnostics, so that a
    /// later run can skip them.
    inspect: ?fs.clean_file_cache.Handle,
    fix: Fixing,

    /// A clean verdict holds for one file alone. A run that rewrites files or
    /// reads other files to judge this one cannot use it.
    fn prepare(opts: Options, project: *const lint.Project) Operation {
        if (opts.fixing) |fixing| return .{ .fix = fixing };
        if (project.hasCrossFileRules()) return .{ .inspect = null };

        return .{ .inspect = opts.cache };
    }

    fn analyze(
        operation: Operation,
        io: std.Io,
        arena: *std.heap.ArenaAllocator,
        project: *lint.Project,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !FileDiagnostics {
        const allocator = arena.allocator();

        switch (operation) {
            .fix => |fixing| return fixing.apply(io, arena, project, lang, source, path),
            .inspect => |cache| {
                const clean = cache orelse
                    return FileDiagnostics.init(allocator, path, lang, source, try project.lint(allocator, source, lang, path));

                const entry = clean.entry(.{ .language = lang, .source = source, .path = path });
                if (entry.isClean(io)) return FileDiagnostics.init(allocator, path, lang, source, &.{});

                const diagnostics = try project.lint(allocator, source, lang, path);
                if (diagnostics.len == 0) entry.markClean(io);

                return FileDiagnostics.init(allocator, path, lang, source, diagnostics);
            },
        }
    }
};

/// Lints one file at a time and hands the result to the check report.
const FileCheck = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    project: *lint.Project,
    baseline: ?Baseline,
    operation: Operation,
    shown: *CheckReport,

    fn checkPath(files: FileCheck, path: []const u8) !void {
        const lang = fs.source.languageOf(path) orelse return error.UnsupportedTarget;

        const source = try fs.source.read(files.io, files.gpa, path);
        defer files.gpa.free(source);

        try files.check(lang, source, path);
    }

    fn check(files: FileCheck, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
        if (try fs.rules.isFixturePath(files.io, path)) return;

        var arena_state = std.heap.ArenaAllocator.init(files.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const linted = try files.operation.analyze(files.io, &arena_state, files.project, lang, source, path);
        if (files.baseline) |*baseline| try baseline.demote(arena, files.project.engine, linted);
        try files.shown.file(arena, linted);
    }
};

/// The violations of the project rules, one entry per file, each with the
/// fingerprints of its diagnostics.
fn projectFiles(arena: std.mem.Allocator, io: std.Io, project: *const lint.Project) ![]const check_report.ProjectFileViolations {
    // the engine returns the violations ordered by path.
    var rest: []const lint.project_rule.Violation = try project.diagnostics(arena, null);

    var files: std.ArrayList(check_report.ProjectFileViolations) = .empty;
    while (rest.len > 0) {
        const path = rest[0].path;

        var count: usize = 1;
        while (count < rest.len and std.mem.eql(u8, path, rest[count].path)) count += 1;

        const diagnostics = try arena.alloc(Diagnostic, count);
        for (rest[0..count], diagnostics) |violation, *d| d.* = violation.diagnostic;
        rest = rest[count..];

        try lint.fingerprint.assign(arena, path, try fs.source.read(io, arena, path), diagnostics);
        try files.append(arena, .{ .path = path, .diagnostics = diagnostics });
    }

    return files.items;
}

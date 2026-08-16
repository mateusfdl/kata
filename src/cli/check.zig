const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const reports = @import("../reports.zig");

const Engine = lint.Engine;
const language = lint.language;

const baseline_mod = @import("baseline.zig");
const render_budget = @import("render_budget.zig");

const RenderBudget = render_budget.RenderBudget;

pub const Outcome = enum { clean, violations };
pub const FixLevel = enum { off, safe, unsafe };

pub const Baseline = baseline_mod.Baseline;
pub const backdatedRules = baseline_mod.Baseline.backdatedRules;

pub const Fixing = struct {
    level: FixLevel,
    stderr: *std.Io.Writer,
};

pub const Options = struct {
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule = &.{},
    max_matches: u32 = 25,
    baseline: ?Baseline = null,
    fixing: ?Fixing = null,
    cache: ?fs.result_cache.Handle = null,

    fn resolveCache(opts: *const Options, engine: *const Engine) ?fs.result_cache.Handle {
        if (opts.fixing != null) return null;
        if (opts.project_rules.len > 0) return null;
        if (engine.factRules().len > 0) return null;

        return opts.cache;
    }
};

const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    project: *lint.Project,
    opts: *const Options,
    cache: ?fs.result_cache.Handle,
    budget: *RenderBudget,
    reporter: *reports.Reporter,

    pub fn run(
        io: std.Io,
        gpa: std.mem.Allocator,
        engine: *Engine,
        opts: Options,
        reporter: *reports.Reporter,
    ) !Outcome {
        const stat = try fs.source.statTarget(io, opts.target);
        var project = try lint.Project.init(gpa, engine, opts.project_rules);
        defer project.deinit();

        // One budget covers the complete run. Files consume it in walk order;
        // project violations consume what remains after indexing finishes.
        var budget: RenderBudget = .{ .gpa = gpa };
        defer budget.deinit();

        const context: Context = .{
            .io = io,
            .gpa = gpa,
            .project = &project,
            .opts = &opts,
            .cache = opts.resolveCache(engine),
            .budget = &budget,
            .reporter = reporter,
        };

        var counts = switch (stat.kind) {
            .directory => try context.checkDir(),
            .file => try context.checkFile(),
            else => return error.UnsupportedTarget,
        };

        counts.add(try context.reportProjectViolations());

        var summary_arena = std.heap.ArenaAllocator.init(gpa);
        defer summary_arena.deinit();

        try reporter.finish(counts, try budget.overflow(summary_arena.allocator()));

        return if (counts.violations > 0) .violations else .clean;
    }

    fn checkFile(context: *const Context) !reports.Counts {
        const lang = fs.source.languageOf(context.opts.target) orelse return error.UnsupportedTarget;

        const source = try fs.source.read(context.io, context.gpa, context.opts.target);
        defer context.gpa.free(source);

        return context.reportFile(lang, source, context.opts.target);
    }

    fn checkDir(context: *const Context) !reports.Counts {
        var counts: reports.Counts = .{};
        const visit: DirVisit = .{
            .context = context,
            .counts = &counts,
        };

        _ = try fs.source.walkFiles(context.io, context.gpa, context.opts.target, visit, DirVisit.file);

        return counts;
    }

    fn reportFile(
        context: *const Context,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !reports.Counts {
        if (try fs.rules.isFixturePath(context.io, path)) return .{};

        var arena = std.heap.ArenaAllocator.init(context.gpa);
        defer arena.deinit();

        var content_hash: [32]u8 = undefined;
        if (context.cache) |c| {
            std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});

            if (c.isClean(context.io, content_hash, path)) {
                try context.reporter.file(path, source, &.{});

                return .{ .files = 1 };
            }
        }

        var current = source;
        const diagnostics = if (context.opts.fixing) |f| fix: {
            std.debug.assert(f.level != .off);

            const result = try context.project.engine.fix(
                &arena,
                current,
                lang,
                path,
                if (f.level == .safe) .safe else .unsafe,
            );
            if (result.status == .syntax_error) {
                try f.stderr.print("kata check: fix for [{s}] introduces a syntax error in {s}\n", .{
                    try std.mem.join(arena.allocator(), ", ", result.rule_ids),
                    path,
                });
                try f.stderr.flush();
            }
            if (result.changed) {
                try fs.source.write(context.io, path, result.source);
                current = result.source;
            }

            try context.project.replace(current, lang, path);

            break :fix result.diagnostics;
        } else try context.project.lint(arena.allocator(), current, lang, path);

        // Fingerprint fixed source before baseline changes severity. Caps,
        // collapse, and rendering affect output only, not diagnostic identity.
        try lint.fingerprint.assign(arena.allocator(), path, current, diagnostics);

        if (context.opts.baseline) |*b|
            try Baseline.apply(context.io, arena.allocator(), context.project.engine, b, lang, current, path, diagnostics);

        if (context.cache) |c| {
            if (diagnostics.len == 0) c.markClean(context.io, content_hash, path);
        }

        const capped = try lint.caps.apply(
            arena.allocator(),
            diagnostics,
            context.project.engine.settings,
            context.opts.max_matches,
        );
        const collapsed = try lint.caps.collapse(arena.allocator(), capped);
        const rendered = try context.budget.filter(arena.allocator(), collapsed);
        try context.reporter.file(path, current, rendered);

        var counts: reports.Counts = .{ .files = 1 };

        tally(&counts, diagnostics);

        return counts;
    }

    fn reportProjectViolations(context: *const Context) !reports.Counts {
        var arena = std.heap.ArenaAllocator.init(context.gpa);
        defer arena.deinit();
        const violations = try context.project.diagnostics(arena.allocator(), null);

        var counts: reports.Counts = .{};
        var rendered: std.ArrayList(lint.project_rule.Violation) = .empty;
        var start: usize = 0;
        while (start < violations.len) {
            var end = start + 1;
            while (end < violations.len and std.mem.eql(u8, violations[start].path, violations[end].path)) : (end += 1) {}

            const source = try fs.source.read(context.io, arena.allocator(), violations[start].path);
            const diagnostics = try arena.allocator().alloc(lint.diagnostic.Diagnostic, end - start);
            for (violations[start..end], diagnostics) |violation, *d| d.* = violation.diagnostic;
            tally(&counts, diagnostics);
            try lint.fingerprint.assign(arena.allocator(), violations[start].path, source, diagnostics);
            const capped = try lint.caps.apply(
                arena.allocator(),
                diagnostics,
                context.project.engine.settings,
                context.opts.max_matches,
            );
            const within = try context.budget.filter(arena.allocator(), capped);
            for (within) |d| try rendered.append(arena.allocator(), .{ .path = violations[start].path, .diagnostic = d });

            start = end;
        }

        try context.reporter.project(rendered.items);

        return counts;
    }

    fn tally(counts: *reports.Counts, diagnostics: []const lint.diagnostic.Diagnostic) void {
        for (diagnostics) |d| {
            switch (d.severity) {
                .@"error" => counts.violations += 1,
                .warn => counts.warnings += 1,
            }
        }
    }
};

pub const run = Context.run;

const DirVisit = struct {
    context: *const Context,
    counts: *reports.Counts,

    fn file(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
        visit.counts.add(try visit.context.reportFile(lang, source, path));
    }
};

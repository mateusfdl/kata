const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const reports = @import("../reports.zig");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const max_file_bytes = fs.source.max_file_bytes;

pub const Outcome = enum { clean, violations };

pub const Baseline = struct {
    ref: []const u8,
    prefix: []const u8,
    dir: std.Io.Dir,
    backdated: []const []const u8 = &.{},
};

pub const FixLevel = enum { off, safe, unsafe };

pub const Fixing = struct {
    level: FixLevel,
    stderr: *std.Io.Writer,
};

pub const render_budget_per_rule: usize = 200;

pub const RenderBudget = struct {
    gpa: std.mem.Allocator,
    per_rule: usize = render_budget_per_rule,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        rendered: usize = 0,
        suppressed: usize = 0,
        files: usize = 0,
    };

    pub fn deinit(self: *RenderBudget) void {
        self.entries.deinit(self.gpa);
    }

    fn take(self: *RenderBudget, rule_id: []const u8) !bool {
        const gop = try self.entries.getOrPut(self.gpa, rule_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        if (gop.value_ptr.rendered >= self.per_rule) return false;

        gop.value_ptr.rendered += 1;

        return true;
    }

    fn recordSuppressed(self: *RenderBudget, rule_id: []const u8, count: usize) !void {
        if (count == 0) return;

        const gop = try self.entries.getOrPut(self.gpa, rule_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        gop.value_ptr.suppressed += count;
        gop.value_ptr.files += 1;
    }

    pub fn overflow(self: *RenderBudget, arena: std.mem.Allocator) ![]const reports.RuleOverflow {
        var out: std.ArrayList(reports.RuleOverflow) = .empty;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.suppressed == 0) continue;

            try out.append(arena, .{
                .rule_id = entry.key_ptr.*,
                .suppressed = entry.value_ptr.suppressed,
                .files = entry.value_ptr.files,
            });
        }

        const items = try out.toOwnedSlice(arena);
        std.mem.sort(reports.RuleOverflow, items, {}, lessByRuleId);

        return items;
    }

    fn lessByRuleId(_: void, a: reports.RuleOverflow, b: reports.RuleOverflow) bool {
        return std.mem.order(u8, a.rule_id, b.rule_id) == .lt;
    }
};

fn withinBudget(
    arena: std.mem.Allocator,
    budget: ?*RenderBudget,
    diagnostics: []const lint.diagnostic.Diagnostic,
) ![]const lint.diagnostic.Diagnostic {
    const b = budget orelse return diagnostics;

    var out: std.ArrayList(lint.diagnostic.Diagnostic) = .empty;
    var suppressed: std.StringHashMapUnmanaged(usize) = .empty;

    for (diagnostics) |d| {
        if (try b.take(d.rule_id)) {
            try out.append(arena, d);
            continue;
        }

        const gop = try suppressed.getOrPut(arena, d.rule_id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }

    var it = suppressed.iterator();
    while (it.next()) |entry| try b.recordSuppressed(entry.key_ptr.*, entry.value_ptr.*);

    return out.toOwnedSlice(arena);
}

pub const Options = struct {
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule = &.{},
    max_matches: u32 = 25,
    baseline: ?Baseline = null,
    fixing: ?Fixing = null,
    cache: ?fs.result_cache.Handle = null,
    budget: ?*RenderBudget = null,
};

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

    var budget: RenderBudget = .{ .gpa = gpa };
    defer budget.deinit();

    var effective = opts;
    effective.cache = cacheFor(opts, engine);
    effective.budget = &budget;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, &project, effective, reporter),
        .file => try checkFile(io, gpa, engine, &project, effective, reporter),
        else => return error.UnsupportedTarget,
    };

    counts.add(try reportProjectViolations(io, gpa, &project, effective, reporter));

    var summary_arena = std.heap.ArenaAllocator.init(gpa);
    defer summary_arena.deinit();

    try reporter.finish(counts, try budget.overflow(summary_arena.allocator()));

    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    project: *lint.Project,
    opts: Options,
    reporter: *reports.Reporter,
) !reports.Counts {
    const lang = fs.source.languageOf(opts.target) orelse return error.UnsupportedTarget;

    const source = try fs.source.read(io, gpa, opts.target);
    defer gpa.free(source);

    return reportFile(io, gpa, engine, lang, source, opts.target, project, opts, reporter);
}

const DirVisit = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    project: *lint.Project,
    opts: Options,
    reporter: *reports.Reporter,
    counts: *reports.Counts,
};

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    project: *lint.Project,
    opts: Options,
    reporter: *reports.Reporter,
) !reports.Counts {
    var counts: reports.Counts = .{};
    const visit: DirVisit = .{
        .io = io,
        .gpa = gpa,
        .engine = engine,
        .project = project,
        .opts = opts,
        .reporter = reporter,
        .counts = &counts,
    };

    _ = try fs.source.walkFiles(io, gpa, opts.target, visit, visitFile);

    return counts;
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.counts.add(try reportFile(visit.io, visit.gpa, visit.engine, lang, source, path, visit.project, visit.opts, visit.reporter));
}

fn reportFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    project: *lint.Project,
    opts: Options,
    reporter: *reports.Reporter,
) !reports.Counts {
    if (try fs.rules.isFixturePath(io, path)) return .{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var content_hash: [32]u8 = undefined;
    if (opts.cache) |c| {
        std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});

        if (c.isClean(io, content_hash, path)) {
            try reporter.file(path, source, &.{});

            return .{ .files = 1 };
        }
    }

    var current = source;
    var needs_index = false;
    const diagnostics = if (opts.fixing) |f| fix: {
        if (f.level == .off) break :fix try project.lint(arena.allocator(), current, lang, path);
        needs_index = true;

        const result = try engine.fix(
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
            try fs.source.write(io, path, result.source);
            current = result.source;
        }

        break :fix result.diagnostics;
    } else try project.lint(arena.allocator(), current, lang, path);

    try lint.fingerprint.assign(arena.allocator(), path, current, diagnostics);

    if (opts.baseline) |b| try applyBaseline(io, arena.allocator(), engine, b, lang, current, path, diagnostics);

    if (needs_index) try project.replace(current, lang, path);

    if (opts.cache) |c| {
        if (diagnostics.len == 0) c.markClean(io, content_hash, path);
    }

    const capped = try lint.caps.apply(arena.allocator(), diagnostics, engine.settings, opts.max_matches);
    const collapsed = try lint.caps.collapse(arena.allocator(), capped);
    const rendered = try withinBudget(arena.allocator(), opts.budget, collapsed);
    try reporter.file(path, current, rendered);

    var counts: reports.Counts = .{ .files = 1 };

    tally(&counts, diagnostics);

    return counts;
}

fn cacheFor(opts: Options, engine: *const Engine) ?fs.result_cache.Handle {
    if (opts.fixing != null) return null;
    if (opts.project_rules.len > 0) return null;
    if (engine.factRules().len > 0) return null;

    return opts.cache;
}

pub fn backdatedRules(
    io: std.Io,
    arena: std.mem.Allocator,
    baseline: Baseline,
    root: ?[]const u8,
    rule_set: *const lint.RuleSet,
) ![]const []const u8 {
    const project_root = root orelse return &.{};
    const base = try repoBase(arena, baseline.prefix, project_root);

    var out: std.ArrayList([]const u8) = .empty;

    const rules_path = try std.fmt.allocPrint(arena, "{s}{s}/rules", .{ base, fs.discover.project_dir_name });
    const ref_files = try fs.git.listFiles(io, arena, baseline.dir, baseline.ref, rules_path);
    try appendEnabledAfterRef(arena, &out, rule_set, ref_files);

    const yaml_path = try std.fmt.allocPrint(arena, "{s}{s}/rules.yaml", .{ base, fs.discover.project_dir_name });
    if (try fs.git.showFile(io, arena, baseline.dir, baseline.ref, yaml_path)) |bytes| {
        try appendRaisedAfterRef(arena, &out, bytes);
    }

    return out.toOwnedSlice(arena);
}

fn repoBase(arena: std.mem.Allocator, prefix: []const u8, root: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return prefix;
    const cleaned = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[2..] else trimmed;

    return std.fmt.allocPrint(arena, "{s}{s}/", .{ prefix, cleaned });
}

fn appendEnabledAfterRef(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    rule_set: *const lint.RuleSet,
    ref_files: []const []const u8,
) !void {
    for (std.enums.values(language.Name)) |lang| {
        for (rule_set.get(lang)) |raw| try appendIfMissingAtRef(arena, out, raw, ref_files);
    }
    for (rule_set.projectRaws()) |raw| try appendIfMissingAtRef(arena, out, raw, ref_files);
}

fn appendIfMissingAtRef(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    raw: lint.rule.RawRule,
    ref_files: []const []const u8,
) !void {
    if (raw.origin != .project) return;
    if (containsId(out.items, raw.id)) return;

    const suffix = try std.fmt.allocPrint(arena, "/{s}{s}", .{ raw.id, fs.rules.kata_suffix });
    for (ref_files) |path| {
        if (std.mem.endsWith(u8, path, suffix)) return;
    }

    try out.append(arena, raw.id);
}

fn appendRaisedAfterRef(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    bytes: []const u8,
) !void {
    var diag: sources.config.Diagnostic = .{};
    const cfg = sources.config.parse(arena, bytes, &diag) catch return;

    for (cfg.settings) |setting| {
        if (setting.project) continue;
        if (containsId(out.items, setting.id)) continue;
        if (!setting.enabled or (setting.severity orelse .@"error") == .warn) try out.append(arena, setting.id);
    }
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }

    return false;
}

fn applyBaseline(
    io: std.Io,
    arena: std.mem.Allocator,
    engine: *Engine,
    b: Baseline,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    diagnostics: []lint.diagnostic.Diagnostic,
) !void {
    if (!lint.diagnostic.hasErrors(diagnostics)) return;

    for (diagnostics) |*d| {
        if (d.severity != .@"error") continue;
        if (!containsId(b.backdated, d.rule_id)) continue;
        d.severity = .warn;
        d.demoted = true;
    }
    if (!lint.diagnostic.hasErrors(diagnostics)) return;

    const repo_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ b.prefix, path });
    const baseline_source = (try fs.git.showFile(io, arena, b.dir, b.ref, repo_path)) orelse return;
    const before = try engine.lint(arena, baseline_source, lang, path);
    try lint.fingerprint.assign(arena, path, baseline_source, before);
    _ = try lint.baseline.demote(arena, source, diagnostics, baseline_source, before);
}

fn reportProjectViolations(
    io: std.Io,
    gpa: std.mem.Allocator,
    project: *const lint.Project,
    opts: Options,
    reporter: *reports.Reporter,
) !reports.Counts {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const violations = try project.diagnostics(arena.allocator(), null);

    var rendered: std.ArrayList(lint.project_rule.Violation) = .empty;
    var start: usize = 0;
    while (start < violations.len) {
        var end = start + 1;
        while (end < violations.len and std.mem.eql(u8, violations[start].path, violations[end].path)) : (end += 1) {}

        const source = try fs.source.read(io, arena.allocator(), violations[start].path);
        const diagnostics = try arena.allocator().alloc(lint.diagnostic.Diagnostic, end - start);
        for (violations[start..end], diagnostics) |violation, *d| d.* = violation.diagnostic;
        try lint.fingerprint.assign(arena.allocator(), violations[start].path, source, diagnostics);
        const capped = try lint.caps.apply(arena.allocator(), diagnostics, project.engine.settings, opts.max_matches);
        const within = try withinBudget(arena.allocator(), opts.budget, capped);
        for (within) |d| try rendered.append(arena.allocator(), .{ .path = violations[start].path, .diagnostic = d });

        start = end;
    }

    try reporter.project(rendered.items);

    var counts: reports.Counts = .{};
    for (violations) |v| tally(&counts, &.{v.diagnostic});

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

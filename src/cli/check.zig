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

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule,
    baseline: ?Baseline,
    fixing: ?Fixing,
    reporter: *reports.Reporter,
) !Outcome {
    const stat = try fs.source.statTarget(io, target);
    const fact_rules = try engine.ensureCompiledFact();

    var index = lint.ProjectIndex.init(gpa);
    defer index.deinit();
    const index_ptr: ?*lint.ProjectIndex = if (project_rules.len > 0 or fact_rules.len > 0) &index else null;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, index_ptr, baseline, fixing, reporter),
        .file => try checkFile(io, gpa, engine, target, index_ptr, baseline, fixing, reporter),
        else => return error.UnsupportedTarget,
    };

    if (index_ptr) |idx| counts.add(try reportProjectViolations(io, gpa, engine, project_rules, fact_rules, idx, reporter));

    try reporter.finish(counts);

    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    baseline: ?Baseline,
    fixing: ?Fixing,
    reporter: *reports.Reporter,
) !reports.Counts {
    const lang = fs.source.languageOf(target) orelse return error.UnsupportedTarget;

    const source = try fs.source.read(io, gpa, target);
    defer gpa.free(source);

    return reportFile(io, gpa, engine, lang, source, target, index, baseline, fixing, reporter);
}

const DirVisit = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    index: ?*lint.ProjectIndex,
    baseline: ?Baseline,
    fixing: ?Fixing,
    reporter: *reports.Reporter,
    counts: *reports.Counts,
};

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    baseline: ?Baseline,
    fixing: ?Fixing,
    reporter: *reports.Reporter,
) !reports.Counts {
    var counts: reports.Counts = .{};
    const visit: DirVisit = .{
        .io = io,
        .gpa = gpa,
        .engine = engine,
        .index = index,
        .baseline = baseline,
        .fixing = fixing,
        .reporter = reporter,
        .counts = &counts,
    };

    _ = try fs.source.walkFiles(io, gpa, target, visit, visitFile);

    return counts;
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.counts.add(try reportFile(visit.io, visit.gpa, visit.engine, lang, source, path, visit.index, visit.baseline, visit.fixing, visit.reporter));
}

fn reportFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    index: ?*lint.ProjectIndex,
    baseline: ?Baseline,
    fixing: ?Fixing,
    reporter: *reports.Reporter,
) !reports.Counts {
    if (try fs.rules.isFixturePath(io, path)) return .{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var current = source;
    var diagnostics = try engine.lint(arena.allocator(), current, lang, path);

    if (fixing) |f| {
        if (f.level != .off) {
            const fixed = try applyFixes(io, arena.allocator(), engine, lang, current, path, &diagnostics, f);
            if (fixed) |bytes| current = bytes;
        }
    }

    try lint.fingerprint.assign(arena.allocator(), path, current, diagnostics);

    if (baseline) |b| try applyBaseline(io, arena.allocator(), engine, b, lang, current, path, diagnostics);

    if (index) |idx| try idx.put(try engine.extractFacts(idx.allocator, current, lang, path));

    try reporter.file(path, current, diagnostics);

    var counts: reports.Counts = .{ .files = 1 };

    tally(&counts, diagnostics);

    return counts;
}

fn applyFixes(
    io: std.Io,
    arena: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    diagnostics: *[]lint.diagnostic.Diagnostic,
    fixing: Fixing,
) !?[]const u8 {
    var current = source;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        const applicable = try applicableFixes(arena, engine, lang, diagnostics.*, fixing.level);
        if (applicable.fixes.len == 0) break;

        const list = try lint.edits.fromFixes(arena, current, applicable.fixes);
        const applied = try lint.edits.apply(arena, current, list);
        if (try engine.hasSyntaxError(applied.source, lang)) {
            try fixing.stderr.print("kata check: fix for [{s}] introduces a syntax error in {s}\n", .{
                try std.mem.join(arena, ", ", applicable.rule_ids),
                path,
            });
            try fixing.stderr.flush();

            break;
        }

        current = applied.source;
        diagnostics.* = try engine.lint(arena, current, lang, path);
    }

    if (current.ptr == source.ptr) return null;

    try fs.source.write(io, path, current);

    return current;
}

const Applicable = struct {
    fixes: []const lint.diagnostic.Fix,
    rule_ids: []const []const u8,
};

fn applicableFixes(
    arena: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    diagnostics: []const lint.diagnostic.Diagnostic,
    level: FixLevel,
) !Applicable {
    var fixes: std.ArrayList(lint.diagnostic.Fix) = .empty;
    var rule_ids: std.ArrayList([]const u8) = .empty;
    for (diagnostics) |d| {
        const fix = d.fix orelse continue;
        const override = engine.fixOverride(lang, d.rule_id);
        if (override == .never) continue;
        if (fix.safety == .unsafe and level != .unsafe and override != .unsafe_ok) continue;

        try fixes.append(arena, fix);
        if (!containsId(rule_ids.items, d.rule_id)) try rule_ids.append(arena, d.rule_id);
    }

    return .{
        .fixes = try fixes.toOwnedSlice(arena),
        .rule_ids = try rule_ids.toOwnedSlice(arena),
    };
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
    engine: *Engine,
    project_rules: []const lint.project_rule.ProjectRule,
    fact_rules: []const lint.fact_rule.CompiledFactRule,
    index: *const lint.ProjectIndex,
    reporter: *reports.Reporter,
) !reports.Counts {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const yaml_violations = try lint.project_rule.evaluate(arena.allocator(), project_rules, engine.settings, index, null);
    const fact_violations = try lint.fact_rule.evaluate(arena.allocator(), fact_rules, engine.settings, index, null);
    const violations = try std.mem.concat(arena.allocator(), lint.project_rule.Violation, &.{ yaml_violations, fact_violations });

    std.mem.sort(lint.project_rule.Violation, violations, {}, lint.project_rule.violationLessThan);

    var start: usize = 0;
    while (start < violations.len) {
        var end = start + 1;
        while (end < violations.len and std.mem.eql(u8, violations[start].path, violations[end].path)) : (end += 1) {}

        const source = try fs.source.read(io, arena.allocator(), violations[start].path);
        const diagnostics = try arena.allocator().alloc(lint.diagnostic.Diagnostic, end - start);
        for (violations[start..end], diagnostics) |violation, *d| d.* = violation.diagnostic;
        try lint.fingerprint.assign(arena.allocator(), violations[start].path, source, diagnostics);
        for (violations[start..end], diagnostics) |*violation, d| violation.diagnostic.fingerprint = d.fingerprint;

        start = end;
    }

    try reporter.project(violations);

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

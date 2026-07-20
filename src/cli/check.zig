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

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule,
    baseline: ?Baseline,
    reporter: *reports.Reporter,
) !Outcome {
    const stat = try fs.source.statTarget(io, target);
    const fact_rules = try engine.ensureCompiledFact();

    var index = lint.ProjectIndex.init(gpa);
    defer index.deinit();
    const index_ptr: ?*lint.ProjectIndex = if (project_rules.len > 0 or fact_rules.len > 0) &index else null;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, index_ptr, baseline, reporter),
        .file => try checkFile(io, gpa, engine, target, index_ptr, baseline, reporter),
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
    reporter: *reports.Reporter,
) !reports.Counts {
    const lang = fs.source.languageOf(target) orelse return error.UnsupportedTarget;

    const source = try fs.source.read(io, gpa, target);
    defer gpa.free(source);

    return reportFile(io, gpa, engine, lang, source, target, index, baseline, reporter);
}

const DirVisit = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    index: ?*lint.ProjectIndex,
    baseline: ?Baseline,
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
    reporter: *reports.Reporter,
) !reports.Counts {
    var counts: reports.Counts = .{};
    const visit: DirVisit = .{
        .io = io,
        .gpa = gpa,
        .engine = engine,
        .index = index,
        .baseline = baseline,
        .reporter = reporter,
        .counts = &counts,
    };

    _ = try fs.source.walkFiles(io, gpa, target, visit, visitFile);

    return counts;
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.counts.add(try reportFile(visit.io, visit.gpa, visit.engine, lang, source, path, visit.index, visit.baseline, visit.reporter));
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
    reporter: *reports.Reporter,
) !reports.Counts {
    if (try fs.rules.isFixturePath(io, path)) return .{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diagnostics = try engine.lint(arena.allocator(), source, lang, path);
    try lint.fingerprint.assign(arena.allocator(), path, source, diagnostics);

    if (baseline) |b| try applyBaseline(io, arena.allocator(), engine, b, lang, source, path, diagnostics);

    if (index) |idx| try idx.put(try engine.extractFacts(idx.allocator, source, lang, path));

    try reporter.file(path, source, diagnostics);

    var counts: reports.Counts = .{ .files = 1 };

    tally(&counts, diagnostics);

    return counts;
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

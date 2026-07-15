const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const reports = @import("../reports.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const max_file_bytes = fs.source.max_file_bytes;

pub const Outcome = enum { clean, violations };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule,
    reporter: *reports.Reporter,
) !Outcome {
    const stat = try fs.source.statTarget(io, target);
    const fact_rules = try engine.ensureCompiledFact();

    var index = lint.ProjectIndex.init(gpa);
    defer index.deinit();
    const index_ptr: ?*lint.ProjectIndex = if (project_rules.len > 0 or fact_rules.len > 0) &index else null;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, index_ptr, reporter),
        .file => try checkFile(io, gpa, engine, target, index_ptr, reporter),
        else => return error.UnsupportedTarget,
    };

    if (index_ptr) |idx| counts.add(try reportProjectViolations(gpa, engine, project_rules, fact_rules, idx, reporter));

    try reporter.finish(counts);

    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    reporter: *reports.Reporter,
) !reports.Counts {
    const lang = fs.source.languageOf(target) orelse return error.UnsupportedTarget;

    const source = try fs.source.read(io, gpa, target);
    defer gpa.free(source);

    return reportFile(io, gpa, engine, lang, source, target, index, reporter);
}

const DirVisit = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    index: ?*lint.ProjectIndex,
    reporter: *reports.Reporter,
    counts: *reports.Counts,
};

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    reporter: *reports.Reporter,
) !reports.Counts {
    var counts: reports.Counts = .{};
    const visit: DirVisit = .{
        .io = io,
        .gpa = gpa,
        .engine = engine,
        .index = index,
        .reporter = reporter,
        .counts = &counts,
    };

    _ = try fs.source.walkFiles(io, gpa, target, visit, visitFile);

    return counts;
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.counts.add(try reportFile(visit.io, visit.gpa, visit.engine, lang, source, path, visit.index, visit.reporter));
}

fn reportFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    index: ?*lint.ProjectIndex,
    reporter: *reports.Reporter,
) !reports.Counts {
    if (try fs.rules.isFixturePath(io, path)) return .{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diagnostics = try engine.lint(arena.allocator(), source, lang, path);

    if (index) |idx| try idx.put(try engine.extractFacts(idx.allocator, source, lang, path));

    try reporter.file(path, source, diagnostics);

    var counts: reports.Counts = .{ .files = 1 };

    tally(&counts, diagnostics);

    return counts;
}

fn reportProjectViolations(
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

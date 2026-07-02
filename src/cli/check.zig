const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("../lint.zig");

const Engine = lint.Engine;
const language = lint.language;

pub const max_file_bytes = fs.source.max_file_bytes;

pub const Outcome = enum { clean, violations };

const Counts = struct {
    files: usize = 0,
    violations: usize = 0,
    warnings: usize = 0,

    fn add(self: *Counts, other: Counts) void {
        self.files += other.files;
        self.violations += other.violations;
        self.warnings += other.warnings;
    }
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule,
    stdout: *std.Io.Writer,
) !Outcome {
    const stat = try fs.source.statTarget(io, target);

    var index = lint.ProjectIndex.init(gpa);
    defer index.deinit();
    const index_ptr: ?*lint.ProjectIndex = if (project_rules.len > 0) &index else null;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, index_ptr, stdout),
        .file => try checkFile(io, gpa, engine, target, index_ptr, stdout),
        else => return error.UnsupportedTarget,
    };

    if (index_ptr) |idx| counts.add(try reportProjectViolations(gpa, engine, project_rules, idx, stdout));

    try stdout.print("checked {d} files, {d} violations, {d} warnings\n", .{ counts.files, counts.violations, counts.warnings });
    try stdout.flush();
    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !Counts {
    const lang = fs.source.languageOf(target) orelse return error.UnsupportedTarget;

    const source = try fs.source.read(io, gpa, target);
    defer gpa.free(source);

    return reportFile(gpa, engine, lang, source, target, index, stdout);
}

const DirVisit = struct {
    gpa: std.mem.Allocator,
    engine: *Engine,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
    counts: *Counts,
};

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !Counts {
    var counts: Counts = .{};
    const visit: DirVisit = .{
        .gpa = gpa,
        .engine = engine,
        .index = index,
        .stdout = stdout,
        .counts = &counts,
    };

    _ = try fs.source.walkFiles(io, gpa, target, visit, visitFile);
    return counts;
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.counts.add(try reportFile(visit.gpa, visit.engine, lang, source, path, visit.index, visit.stdout));
}

fn reportFile(
    gpa: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !Counts {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diagnostics = try engine.lint(arena.allocator(), source, lang, path);

    if (index) |idx| try idx.put(try engine.extractFacts(idx.allocator, source, lang, path));

    var counts: Counts = .{ .files = 1 };
    for (diagnostics) |d| {
        try printDiagnostic(stdout, path, d, &counts);
    }
    return counts;
}

fn reportProjectViolations(
    gpa: std.mem.Allocator,
    engine: *Engine,
    project_rules: []const lint.project_rule.ProjectRule,
    index: *const lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !Counts {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const violations = try lint.project_rule.evaluate(arena.allocator(), project_rules, engine.warnings, index);

    var counts: Counts = .{};
    for (violations) |v| {
        try printDiagnostic(stdout, v.path, v.diagnostic, &counts);
    }
    return counts;
}

fn printDiagnostic(
    stdout: *std.Io.Writer,
    path: []const u8,
    d: lint.diagnostic.Diagnostic,
    counts: *Counts,
) !void {
    const marker: []const u8 = switch (d.severity) {
        .@"error" => blk: {
            counts.violations += 1;
            break :blk "";
        },
        .warn => blk: {
            counts.warnings += 1;
            break :blk "warn ";
        },
    };
    try stdout.print("{s}:{d}:{d} {s}[{s}] {s}\n", .{
        path,
        d.range.start.line + 1,
        d.range.start.column + 1,
        marker,
        d.rule_id,
        d.message,
    });
}

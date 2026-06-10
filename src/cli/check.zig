const std = @import("std");

const lint = @import("../lint.zig");
const walk = @import("../sources.zig").walk;

const Engine = lint.Engine;
const language = lint.language;

pub const max_file_bytes = walk.max_file_bytes;

pub const Outcome = enum { clean, violations };

const Counts = struct { files: usize, violations: usize };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    project_rules: []const lint.project_rule.ProjectRule,
    stdout: *std.Io.Writer,
) !Outcome {
    const stat = try std.Io.Dir.cwd().statFile(io, target, .{});

    var index = lint.ProjectIndex.init(gpa);
    defer index.deinit();
    const index_ptr: ?*lint.ProjectIndex = if (project_rules.len > 0) &index else null;

    var counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, index_ptr, stdout),
        .file => try checkFile(io, gpa, engine, target, index_ptr, stdout),
        else => return error.UnsupportedTarget,
    };

    if (index_ptr) |idx| counts.violations += try reportProjectViolations(gpa, project_rules, idx, stdout);

    try stdout.print("checked {d} files, {d} violations\n", .{ counts.files, counts.violations });
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
    const lang = walk.languageOf(target) orelse return error.UnsupportedTarget;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(max_file_bytes));
    defer gpa.free(source);

    return .{ .files = 1, .violations = try reportFile(gpa, engine, lang, source, target, index, stdout) };
}

const DirVisit = struct {
    gpa: std.mem.Allocator,
    engine: *Engine,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
    violations: *usize,
};

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !Counts {
    var violations: usize = 0;
    const visit: DirVisit = .{
        .gpa = gpa,
        .engine = engine,
        .index = index,
        .stdout = stdout,
        .violations = &violations,
    };
    const files = try walk.walkSourceFiles(io, gpa, target, visit, visitFile);
    return .{ .files = files, .violations = violations };
}

fn visitFile(visit: DirVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    visit.violations.* += try reportFile(visit.gpa, visit.engine, lang, source, path, visit.index, visit.stdout);
}

fn reportFile(
    gpa: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    index: ?*lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diagnostics = try engine.lint(arena.allocator(), source, lang, path);

    if (index) |idx| try idx.put(try engine.extractFacts(idx.allocator, source, lang, path));

    for (diagnostics) |d| {
        try stdout.print("{s}:{d}:{d} [{s}] {s}\n", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.rule_id,
            d.message,
        });
    }
    return diagnostics.len;
}

fn reportProjectViolations(
    gpa: std.mem.Allocator,
    project_rules: []const lint.project_rule.ProjectRule,
    index: *const lint.ProjectIndex,
    stdout: *std.Io.Writer,
) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const violations = try lint.project_rule.evaluate(arena.allocator(), project_rules, index);

    for (violations) |v| {
        try stdout.print("{s}:{d}:{d} [{s}] {s}\n", .{
            v.path,
            v.diagnostic.range.start.line + 1,
            v.diagnostic.range.start.column + 1,
            v.diagnostic.rule_id,
            v.diagnostic.message,
        });
    }
    return violations.len;
}

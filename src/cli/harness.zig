const std = @import("std");

const lint = @import("../lint.zig");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const language = lint.language;
const loader = sources.loader;
const walk = sources.walk;

const expect_marker = "// kata-expect:";

pub const Outcome = enum { pass, failures, invalid };

const Expectation = struct {
    line: u32,
    rule_id: []const u8,
    matched: bool = false,
};

const Totals = struct {
    fixtures: usize = 0,
    failures: usize = 0,
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    rules_dir: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Outcome {
    var registry = language.Registry.init();
    var rule_set = loader.load(arena, io, .{ .external_dir = rules_dir, .skip_embedded = true }) catch |err| {
        try stderr.print("kata test: cannot load rules from \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
        try stderr.flush();
        return .invalid;
    };
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &registry, &rule_set);
    defer engine.deinit();
    engine.prewarm() catch {
        try engine.compile_diag.write("kata test", stderr);
        return .invalid;
    };

    var totals: Totals = .{};
    var root = std.Io.Dir.cwd().openDir(io, rules_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("kata test: cannot open \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
        try stderr.flush();
        return .invalid;
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const lang_subdir = try arena.dupe(u8, entry.name);
        try runLangFixtures(io, arena, &engine, &root, rules_dir, lang_subdir, stdout, &totals);
    }

    try stdout.print("tested {d} fixtures, {d} failures\n", .{ totals.fixtures, totals.failures });
    try stdout.flush();
    return if (totals.failures > 0) .failures else .pass;
}

fn runLangFixtures(
    io: std.Io,
    arena: std.mem.Allocator,
    engine: *Engine,
    root: *std.Io.Dir,
    rules_dir: []const u8,
    lang_subdir: []const u8,
    stdout: *std.Io.Writer,
    totals: *Totals,
) !void {
    var lang_dir = try root.openDir(io, lang_subdir, .{});
    defer lang_dir.close(io);

    var tests_dir = lang_dir.openDir(io, "tests", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer tests_dir.close(io);

    var it = tests_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const lang = walk.languageOf(entry.name) orelse continue;
        const source = try tests_dir.readFileAlloc(io, entry.name, arena, .limited(walk.max_file_bytes));
        const path = try std.fmt.allocPrint(arena, "{s}/{s}/tests/{s}", .{ rules_dir, lang_subdir, entry.name });
        totals.fixtures += 1;
        totals.failures += try checkFixture(arena, engine, lang, source, path, stdout);
    }
}

fn checkFixture(
    arena: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    stdout: *std.Io.Writer,
) !usize {
    var expectations: std.ArrayList(Expectation) = .empty;
    var annotation_lines: std.ArrayList(u32) = .empty;
    try parseAnnotations(arena, source, &expectations, &annotation_lines);

    const diagnostics = try engine.lint(arena, source, lang, path);

    var failures: usize = 0;
    for (diagnostics) |d| {
        const line = d.range.start.line;
        if (containsLine(annotation_lines.items, line)) continue;
        if (claimExpectation(expectations.items, line, d.rule_id)) continue;
        try stdout.print("{s}:{d} unexpected [{s}]\n", .{ path, line + 1, d.rule_id });
        failures += 1;
    }
    for (expectations.items) |e| {
        if (e.matched) continue;
        try stdout.print("{s}:{d} missing [{s}]\n", .{ path, e.line + 1, e.rule_id });
        failures += 1;
    }
    return failures;
}

fn parseAnnotations(
    arena: std.mem.Allocator,
    source: []const u8,
    expectations: *std.ArrayList(Expectation),
    annotation_lines: *std.ArrayList(u32),
) !void {
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, expect_marker)) continue;
        try annotation_lines.append(arena, line_no);
        var ids = std.mem.tokenizeAny(u8, line[expect_marker.len..], ", ");
        while (ids.next()) |id| {
            try expectations.append(arena, .{ .line = line_no + 1, .rule_id = id });
        }
    }
}

fn containsLine(lines: []const u32, line: u32) bool {
    for (lines) |l| {
        if (l == line) return true;
    }
    return false;
}

fn claimExpectation(expectations: []Expectation, line: u32, rule_id: []const u8) bool {
    for (expectations) |*e| {
        if (e.matched or e.line != line) continue;
        if (!std.mem.eql(u8, e.rule_id, rule_id)) continue;
        e.matched = true;
        return true;
    }
    return false;
}

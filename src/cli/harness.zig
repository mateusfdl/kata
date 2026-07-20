const std = @import("std");

const dsl = @import("dsl");
const fs = @import("../fs.zig");
const lint = @import("engine");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const language = lint.language;
const lifecycle = sources.lifecycle;
const loader = sources.loader;
const expect_marker = "// kata-expect:";
const expect_fix_marker = "// kata-expect-fix:";

pub const Outcome = enum { pass, failures, invalid };

const Expectation = struct {
    line: u32,
    rule_id: []const u8,
    matched: bool = false,
};

const FixExpectation = struct {
    line: u32,
    replacement: []const u8,
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
    var rule_set = loader.load(arena, io, .{ .project_dir = rules_dir, .skip_embedded = true }) catch |err| {
        try stderr.print("kata test: cannot load rules from \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
        try stderr.flush();
        return .invalid;
    };
    defer rule_set.deinit();

    var rule_diag: lint.rule.Diagnostic = .{};
    const table = lifecycle.build(arena, &rule_set, &rule_diag) catch |err| switch (err) {
        error.LifecycleCollision => {
            try rule_diag.write("kata test", stderr);
            return .invalid;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var engine = Engine.init(gpa, &rule_set, dsl.engine_compiler.ruleCompiler());
    defer engine.deinit();
    if (!try engine.prewarmOrReport("kata test", stderr)) return .invalid;

    var totals: Totals = .{};
    const fixtures = fs.rules.collectFixtureFiles(io, arena, rules_dir) catch |err| {
        try stderr.print("kata test: cannot open \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
        try stderr.flush();
        return .invalid;
    };

    var covered: std.ArrayList([]const u8) = .empty;
    for (fixtures) |fixture| {
        totals.fixtures += 1;
        totals.failures += try checkFixture(arena, &engine, &table, fixture.lang, fixture.source, fixture.path, stdout, &covered);
    }

    for (try engine.rulesWithFixes(arena)) |id| {
        if (containsString(covered.items, id)) continue;

        try stdout.print("warning: rule {s} declares a fix but no fixture asserts it\n", .{id});
    }

    try stdout.print("tested {d} fixtures, {d} failures\n", .{ totals.fixtures, totals.failures });
    try stdout.flush();

    return if (totals.failures > 0) .failures else .pass;
}

fn checkFixture(
    arena: std.mem.Allocator,
    engine: *Engine,
    table: *const lifecycle.Table,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    stdout: *std.Io.Writer,
    covered: *std.ArrayList([]const u8),
) !usize {
    var expectations: std.ArrayList(Expectation) = .empty;
    var fix_expectations: std.ArrayList(FixExpectation) = .empty;
    var annotation_lines: std.ArrayList(u32) = .empty;
    var failures = try parseAnnotations(arena, table, lang, source, path, stdout, &expectations, &fix_expectations, &annotation_lines);

    const diagnostics = try engine.lint(arena, source, lang, path);

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

    failures += try checkFixExpectations(arena, fix_expectations.items, diagnostics, path, stdout, covered);
    failures += try checkFixInvariants(arena, engine, lang, source, path, diagnostics, stdout);

    return failures;
}

fn checkFixExpectations(
    arena: std.mem.Allocator,
    expectations: []FixExpectation,
    diagnostics: []const lint.diagnostic.Diagnostic,
    path: []const u8,
    stdout: *std.Io.Writer,
    covered: *std.ArrayList([]const u8),
) !usize {
    var failures: usize = 0;
    for (diagnostics) |d| {
        const fix = d.fix orelse continue;
        const e = claimFixExpectation(expectations, d.range.start.line) orelse continue;
        if (!containsString(covered.items, d.rule_id)) try covered.append(arena, d.rule_id);
        if (std.mem.eql(u8, e.replacement, fix.replacement)) continue;

        try stdout.print("{s}:{d} wrong fix \"{s}\" (expected \"{s}\")\n", .{ path, e.line + 1, fix.replacement, e.replacement });

        failures += 1;
    }

    for (expectations) |e| {
        if (e.matched) continue;

        try stdout.print("{s}:{d} missing fix\n", .{ path, e.line + 1 });

        failures += 1;
    }

    return failures;
}

fn checkFixInvariants(
    arena: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    diagnostics: []const lint.diagnostic.Diagnostic,
    stdout: *std.Io.Writer,
) !usize {
    var current = source;
    var diags = diagnostics;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        const fixes = try collectFixes(arena, diags);
        if (fixes.len == 0) return 0;

        const list = try lint.edits.fromFixes(arena, current, fixes);
        const applied = try lint.edits.apply(arena, current, list);
        if (try engine.hasSyntaxError(applied.source, lang)) {
            try stdout.print("{s} fix introduces a syntax error [{s}]\n", .{ path, try fixRuleIds(arena, diags) });

            return 1;
        }

        current = applied.source;
        diags = try engine.lint(arena, current, lang, path);
    }

    if ((try collectFixes(arena, diags)).len == 0) return 0;

    try stdout.print("{s} fixes do not converge [{s}]\n", .{ path, try fixRuleIds(arena, diags) });

    return 1;
}

fn collectFixes(arena: std.mem.Allocator, diagnostics: []const lint.diagnostic.Diagnostic) ![]const lint.diagnostic.Fix {
    var out: std.ArrayList(lint.diagnostic.Fix) = .empty;
    for (diagnostics) |d| {
        if (d.fix) |fix| try out.append(arena, fix);
    }

    return out.toOwnedSlice(arena);
}

fn fixRuleIds(arena: std.mem.Allocator, diagnostics: []const lint.diagnostic.Diagnostic) ![]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (diagnostics) |d| {
        if (d.fix == null) continue;
        if (containsString(ids.items, d.rule_id)) continue;

        try ids.append(arena, d.rule_id);
    }

    return std.mem.join(arena, ", ", ids.items);
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }

    return false;
}

fn claimFixExpectation(expectations: []FixExpectation, line: u32) ?*FixExpectation {
    for (expectations) |*e| {
        if (e.matched or e.line != line) continue;

        e.matched = true;

        return e;
    }

    return null;
}

const Annotation = struct {
    line: u32,
    ids: []const []const u8,
};

const FixAnnotation = struct {
    line: u32,
    replacement: []const u8,
};

fn parseAnnotations(
    arena: std.mem.Allocator,
    table: *const lifecycle.Table,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    stdout: *std.Io.Writer,
    expectations: *std.ArrayList(Expectation),
    fix_expectations: *std.ArrayList(FixExpectation),
    annotation_lines: *std.ArrayList(u32),
) !usize {
    var annotations: std.ArrayList(Annotation) = .empty;
    var fix_annotations: std.ArrayList(FixAnnotation) = .empty;
    var line_no: u32 = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (std.mem.startsWith(u8, line, expect_fix_marker)) {
            try annotation_lines.append(arena, line_no);
            try fix_annotations.append(arena, .{
                .line = line_no,
                .replacement = std.mem.trim(u8, line[expect_fix_marker.len..], " \t"),
            });

            continue;
        }

        if (!std.mem.startsWith(u8, line, expect_marker)) continue;

        try annotation_lines.append(arena, line_no);

        var collected: std.ArrayList([]const u8) = .empty;
        var ids = std.mem.tokenizeAny(u8, line[expect_marker.len..], ", \t");

        while (ids.next()) |id| try collected.append(arena, id);

        try annotations.append(arena, .{ .line = line_no, .ids = try collected.toOwnedSlice(arena) });
    }

    var total = line_no;
    if (source.len > 0 and source[source.len - 1] == '\n') total -= 1;

    var failures: usize = 0;
    for (annotations.items) |annotation| {
        if (annotation.ids.len == 0) {
            try stdout.print("{s}:{d} empty kata-expect annotation\n", .{ path, annotation.line + 1 });

            failures += 1;

            continue;
        }

        var target = annotation.line + 1;
        while (containsLine(annotation_lines.items, target)) target += 1;

        if (target >= total) {
            try stdout.print("{s}:{d} dangling kata-expect annotation\n", .{ path, annotation.line + 1 });

            failures += 1;

            continue;
        }

        for (annotation.ids) |id| {
            var rule_id = id;
            switch (table.resolve(lang, id)) {
                .renamed, .replaced => |canonical| {
                    try stdout.print("{s}:{d} renamed [{s} -> {s}]\n", .{ path, annotation.line + 1, id, canonical });

                    rule_id = canonical;
                },
                .live, .removed, .unknown => {},
            }

            try expectations.append(arena, .{ .line = target, .rule_id = rule_id });
        }
    }

    for (fix_annotations.items) |annotation| {
        var target = annotation.line + 1;
        while (containsLine(annotation_lines.items, target)) target += 1;

        if (target >= total) {
            try stdout.print("{s}:{d} dangling kata-expect-fix annotation\n", .{ path, annotation.line + 1 });

            failures += 1;

            continue;
        }

        try fix_expectations.append(arena, .{ .line = target, .replacement = annotation.replacement });
    }

    return failures;
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

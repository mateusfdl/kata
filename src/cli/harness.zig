const std = @import("std");

const annotations = @import("annotations.zig");
const dsl = @import("dsl");
const fs = @import("../fs.zig");
const lint = @import("engine");
const sources = @import("../sources.zig");

const Engine = lint.Engine;
const language = lint.language;
const lifecycle = sources.lifecycle;
const loader = sources.loader;

const Expectation = annotations.Expectation;
const FixExpectation = annotations.FixExpectation;

pub const Outcome = enum { pass, failures, invalid };

const Totals = struct {
    fixtures: usize = 0,
    failures: usize = 0,
};

const Session = struct {
    engine: *Engine,
    table: *const lifecycle.Table,
    stdout: *std.Io.Writer,
    covered: std.ArrayList([]const u8) = .empty,

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

        var engine = Engine.init(gpa, &rule_set, dsl.engine_compiler.ruleCompiler(), &.{});
        defer engine.deinit();
        if (!try engine.prewarmOrReport("kata test", stderr)) return .invalid;

        var totals: Totals = .{};
        const fixtures = fs.rules.collectFixtureFiles(io, arena, rules_dir) catch |err| {
            try stderr.print("kata test: cannot open \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
            try stderr.flush();
            return .invalid;
        };

        var session: Session = .{ .engine = &engine, .table = &table, .stdout = stdout };
        for (fixtures) |fixture| {
            totals.fixtures += 1;
            totals.failures += try session.checkFixture(arena, fixture.lang, fixture.source, fixture.path);
        }

        for (try engine.rulesWithFixes(arena)) |id| {
            if (containsString(session.covered.items, id)) continue;

            try stdout.print("warning: rule {s} declares a fix but no fixture asserts it\n", .{id});
        }

        try stdout.print("tested {d} fixtures, {d} failures\n", .{ totals.fixtures, totals.failures });
        try stdout.flush();

        return if (totals.failures > 0) .failures else .pass;
    }

    fn checkFixture(
        session: *Session,
        arena: std.mem.Allocator,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !usize {
        const stdout = session.stdout;

        var parser: annotations.Parser = .{ .table = session.table, .stdout = stdout };
        var failures = try parser.parse(arena, lang, source, path);

        const diagnostics = try session.engine.lint(arena, source, lang, path);

        for (diagnostics) |d| {
            const line = d.range.start.line;

            if (parser.coversLine(line)) continue;
            if (Expectation.claim(parser.expectations.items, line, d.rule_id)) continue;

            try stdout.print("{s}:{d} unexpected [{s}]\n", .{ path, line + 1, d.rule_id });

            failures += 1;
        }

        for (parser.expectations.items) |e| {
            if (e.matched) continue;

            try stdout.print("{s}:{d} missing [{s}]\n", .{ path, e.line + 1, e.rule_id });

            failures += 1;
        }

        failures += try session.checkFixExpectations(arena, parser.fix_expectations.items, diagnostics, path);
        failures += try session.checkFixInvariants(arena, lang, source, path);

        return failures;
    }

    fn checkFixExpectations(
        session: *Session,
        arena: std.mem.Allocator,
        expectations: []FixExpectation,
        diagnostics: []const lint.diagnostic.Diagnostic,
        path: []const u8,
    ) !usize {
        const stdout = session.stdout;

        var failures: usize = 0;
        for (diagnostics) |d| {
            const fix = d.fix orelse continue;
            const e = FixExpectation.claim(expectations, d.range.start.line) orelse continue;
            if (!containsString(session.covered.items, d.rule_id)) try session.covered.append(arena, d.rule_id);
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
        session: *Session,
        arena: std.mem.Allocator,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !usize {
        const stdout = session.stdout;

        var fix_arena = std.heap.ArenaAllocator.init(arena);
        defer fix_arena.deinit();
        const result = try session.engine.fix(&fix_arena, source, lang, path, .declared);
        switch (result.status) {
            .converged => return 0,
            .syntax_error => try stdout.print("{s} fix introduces a syntax error [{s}]\n", .{
                path,
                try std.mem.join(arena, ", ", result.rule_ids),
            }),
            .pass_limit => try stdout.print("{s} fixes do not converge [{s}]\n", .{
                path,
                try std.mem.join(arena, ", ", result.rule_ids),
            }),
        }

        return 1;
    }

    fn containsString(items: []const []const u8, needle: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
        }

        return false;
    }
};

pub const run = Session.run;

const std = @import("std");

const annotations = @import("annotations.zig");
const cli = @import("cli");
const dsl = @import("dsl");
const fs = @import("../fs.zig");
const lint = @import("engine");
const output = @import("output.zig");
const sources = @import("../sources.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const Engine = lint.Engine;
const Fixture = fs.rules.FixtureFile;
const loader = sources.loader;

const Annotations = annotations.Annotations;

pub const Args = struct {
    rules_dir: []const u8,
};

pub const command = cli.command(Args, .{
    .name = "test",
    .positionals = .{
        .{ .field = .rules_dir, .label = "<rules-dir>" },
    },
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    const rules_dir = parsed.rules_dir;
    const arena = env.arena;
    const stdout = env.stdout;

    var rule_set = loader.load(arena, env.io, .{ .project_dir = rules_dir, .skip_embedded = true }) catch |err|
        return output.failure(env.stderr, "kata test: cannot load rules from \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });
    defer rule_set.deinit();

    var engine = Engine.init(env.gpa, &rule_set, dsl.engine_compiler.ruleCompiler(), &.{});
    defer engine.deinit();
    if (!try engine.prewarmOrReport("kata test", env.stderr)) return error.InternalReported;

    const fixtures = fs.rules.collectFixtureFiles(env.io, arena, rules_dir) catch |err|
        return output.failure(env.stderr, "kata test: cannot open \"{s}\": {s}\n", .{ rules_dir, @errorName(err) });

    var run: Run = .{ .engine = &engine, .failures = .{ .stdout = stdout } };
    for (fixtures) |fixture| try run.checkFixture(arena, fixture);

    for (try engine.rulesWithFixes(arena)) |id| {
        if (run.rules_with_asserted_fix.contains(id)) continue;

        try stdout.print("warning: rule {s} declares a fix but no fixture asserts it\n", .{id});
    }

    try stdout.print("tested {d} fixtures, {d} failures\n", .{ fixtures.len, run.failures.count });
    try stdout.flush();

    return if (run.failures.count > 0) .violations else .clean;
}

/// Every failure is printed when it is found, and counted.
const Failures = struct {
    stdout: *std.Io.Writer,
    count: usize = 0,

    fn add(failures: *Failures, comptime fmt: []const u8, values: anytype) !void {
        try failures.stdout.print(fmt ++ "\n", values);

        failures.count += 1;
    }
};

const Run = struct {
    engine: *Engine,
    failures: Failures,
    rules_with_asserted_fix: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn checkFixture(run: *Run, arena: std.mem.Allocator, fixture: Fixture) !void {
        const path = fixture.path;
        const expected = try Annotations.parse(arena, fixture.source);

        const diagnostics = try run.engine.lint(arena, fixture.source, fixture.lang, path);
        const comparison = try expected.compare(arena, diagnostics);
        for (comparison.problems) |problem| {
            try run.failures.add("{s}:{d} {s}", .{ path, problem.line + 1, problem.message });
        }
        for (comparison.rules_with_asserted_fix) |id| try run.rules_with_asserted_fix.put(arena, id, {});
        try run.checkFixInvariants(arena, fixture);
    }

    /// Applying every declared fix must end, and must leave source that parses.
    fn checkFixInvariants(run: *Run, arena: std.mem.Allocator, fixture: Fixture) !void {
        var fix_arena = std.heap.ArenaAllocator.init(arena);
        defer fix_arena.deinit();

        const result = try run.engine.fix(&fix_arena, fixture.source, fixture.lang, fixture.path, .declared);
        const defect = switch (result.status) {
            .converged => return,
            .syntax_error => "fix introduces a syntax error",
            .pass_limit => "fixes do not converge",
        };

        try run.failures.add("{s} {s} [{s}]", .{ fixture.path, defect, try std.mem.join(arena, ", ", result.rule_ids) });
    }
};

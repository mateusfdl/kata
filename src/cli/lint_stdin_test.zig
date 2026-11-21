const std = @import("std");

const lint_stdin = @import("lint_stdin.zig");
const test_fixture = @import("../test_fixture.zig");

const Exit = @import("exit.zig").Exit;
const TestEnv = @import("test_env.zig").TestEnv;

const diagnostic = @import("engine").diagnostic;
const daemon = @import("../server.zig").daemon;

fn newFixture(gpa: std.mem.Allocator) !*test_fixture.Fixture {
    return test_fixture.Fixture.init(gpa, &.{ .ts, .tsx }, "no-as-any", test_fixture.no_as_any_rule);
}

fn oneShotContext(f: *test_fixture.Fixture) daemon.Context {
    return .{ .policy = .{ .engine = &f.engine }, .io = std.testing.io };
}

const RunResult = struct {
    outcome: anyerror!Exit,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn lint(t: *TestEnv, ctx: daemon.Context, parsed: lint_stdin.Args) !Exit {
    const env = t.env();

    return lint_stdin.lintLocally(env, ctx, try lint_stdin.readInput(env, parsed));
}

fn runCli(
    allocator: std.mem.Allocator,
    ctx: daemon.Context,
    parsed: lint_stdin.Args,
    stdin_bytes: []const u8,
) !RunResult {
    var t: TestEnv = .init(stdin_bytes);
    defer t.deinit();

    const outcome = lint(&t, ctx, parsed);

    const stdout = try allocator.dupe(u8, t.out.written());
    errdefer allocator.free(stdout);

    return .{
        .outcome = outcome,
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, t.err.written()),
    };
}

const Report = struct {
    language: []const u8,
    diagnostics: []const struct {
        rule_id: []const u8,
        language: []const u8,
        message: []const u8,
        range: struct {
            start: struct { line: u32, column: u32 },
            end: struct { line: u32, column: u32 },
        },
        severity: []const u8,
        demoted: bool,
        fingerprint: []const u8,
        context: []const diagnostic.Context,
        fix: ?struct {
            range: struct {
                start: struct { line: u32, column: u32 },
                end: struct { line: u32, column: u32 },
            },
            replacement: []const u8,
            safety: []const u8,
        },
        suggestions: []const struct {
            label: []const u8,
            range: struct {
                start: struct { line: u32, column: u32 },
                end: struct { line: u32, column: u32 },
            },
            replacement: []const u8,
        },
        capped: bool,
    },
    clean: bool,
};

test "lint stdin: grammar maps every flag to its option" {
    try std.testing.expectEqualDeep(
        lint_stdin.command.Result{ .ok = .{ .lang = "ts", .filename = "src/a.ts" } },
        lint_stdin.command.parse(&.{ "--lang=ts", "--filename", "src/a.ts" }),
    );
}

test "lint stdin: clean source reports clean" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{ .lang = "ts" };
    const r = try runCli(gpa, oneShotContext(f), args, "const x: string = \"ok\";");
    defer r.deinit(gpa);

    try std.testing.expectEqual(Exit.clean, try r.outcome);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.clean);
    try std.testing.expectEqualStrings("ts", parsed.value.language);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.diagnostics.len);
}

test "lint stdin: violation reports violations" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{ .lang = "ts" };
    const r = try runCli(gpa, oneShotContext(f), args, "const x = (foo[0] as any).bar;");
    defer r.deinit(gpa);

    try std.testing.expectEqual(Exit.violations, try r.outcome);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.clean);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
    try std.testing.expectEqualStrings("no-as-any", parsed.value.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings("as any is not allowed", parsed.value.diagnostics[0].message);
    try std.testing.expectEqualStrings("error", parsed.value.diagnostics[0].severity);
    try std.testing.expectEqual(false, parsed.value.diagnostics[0].demoted);
    try std.testing.expectEqualStrings("f8442f8df97b699227020f1ca99a3d34007e51a6f4a3934089158471a8f2963b", parsed.value.diagnostics[0].fingerprint);
}

test "lint stdin: --filename infers language" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{ .filename = "/tmp/foo.tsx" };
    const r = try runCli(gpa, oneShotContext(f), args, "const x = foo as any;");
    defer r.deinit(gpa);

    try std.testing.expectEqual(Exit.violations, try r.outcome);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tsx", parsed.value.language);
}

test "lint stdin: missing --lang is a usage error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{};
    const r = try runCli(gpa, oneShotContext(f), args, "x");
    defer r.deinit(gpa);

    try std.testing.expectError(error.UsageReported, r.outcome);
    try std.testing.expectEqualStrings("missing --lang (or provide --filename with a known extension)\n", r.stderr);
}

test "lint stdin: unsupported --lang is an internal error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{ .lang = "python" };
    const r = try runCli(gpa, oneShotContext(f), args, "print('hi')");
    defer r.deinit(gpa);

    try std.testing.expectError(error.InternalReported, r.outcome);
    try std.testing.expectEqualStrings("lint: unsupported language: \"python\"\n", r.stderr);
}

test "lint stdin: unknown extension is a usage error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: lint_stdin.Args = .{ .filename = "foo.rs" };
    const r = try runCli(gpa, oneShotContext(f), args, "fn main() {}");
    defer r.deinit(gpa);

    try std.testing.expectError(error.UsageReported, r.outcome);
    try std.testing.expectEqualStrings("cannot infer language from extension \".rs\"\n", r.stderr);
}

test "lint stdin: caps a flooding rule and stays unclean" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    var ctx = oneShotContext(f);
    ctx.policy.resolved.max_matches_per_file = 1;

    const args: lint_stdin.Args = .{ .lang = "ts" };
    const r = try runCli(gpa, ctx, args, "const a = v as any;\n" ++
        "const b = v as any;\n" ++
        "const c = v as any;\n" ++
        "const d = v as any;\n" ++
        "const e = v as any;\n");
    defer r.deinit(gpa);

    try std.testing.expectEqual(Exit.violations, try r.outcome);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.clean);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.diagnostics.len);
    try std.testing.expectEqual(false, parsed.value.diagnostics[0].capped);
    try std.testing.expectEqual(true, parsed.value.diagnostics[3].capped);
    try std.testing.expectEqualStrings(
        "rule no-as-any fired 5 times in this file; showing 3, suppressed 2; a flood usually means a broken pattern or wrong scope",
        parsed.value.diagnostics[3].message,
    );
}

test "lint stdin: demotes an error matching the file on disk to warn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try newFixture(gpa);
    defer f.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const a = x as any;\n" });

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const filename = try std.fmt.allocPrint(gpa, "{s}/a.ts", .{dir});
    defer gpa.free(filename);

    var ctx = oneShotContext(f);
    ctx.policy.resolved.warn_on_existing_errors = true;

    const args: lint_stdin.Args = .{ .filename = filename };
    const r = try runCli(gpa, ctx, args, "const a = x as any;\n");
    defer r.deinit(gpa);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
    try std.testing.expectEqualStrings("warn", parsed.value.diagnostics[0].severity);
    try std.testing.expectEqual(true, parsed.value.diagnostics[0].demoted);
    try std.testing.expect(parsed.value.clean);
    try std.testing.expectEqual(Exit.clean, try r.outcome);
}

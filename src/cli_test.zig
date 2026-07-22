const std = @import("std");
const cli = @import("cli.zig");
const reports = @import("reports.zig");
const test_fixture = @import("test_fixture.zig");
const args_mod = @import("cli/args.zig");
const build_options = @import("build_options");
const check = @import("cli/check.zig");

const diagnostic = @import("engine").diagnostic;
const Engine = @import("engine").Engine;

fn newFixture(gpa: std.mem.Allocator) !*test_fixture.Fixture {
    return test_fixture.Fixture.init(gpa, &.{ .ts, .tsx }, "no-as-any", test_fixture.no_as_any_rule);
}

const RunResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCli(
    allocator: std.mem.Allocator,
    engine: *Engine,
    args: []const [:0]const u8,
    stdin_bytes: []const u8,
) !RunResult {
    var stdin: std.Io.Reader = .fixed(stdin_bytes);
    var stdout_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer stdout_buf.deinit();
    var stderr_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer stderr_buf.deinit();

    const code = try cli.run(allocator, engine, .{
        .args = args,
        .stdin = &stdin,
        .stdout = &stdout_buf.writer,
        .stderr = &stderr_buf.writer,
    });

    return .{
        .code = code,
        .stdout = try stdout_buf.toOwnedSlice(),
        .stderr = try stderr_buf.toOwnedSlice(),
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
        maturity: []const u8,
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
    },
    clean: bool,
};

test "cli: clean source exits 0" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{"--lang=ts"};
    const r = try runCli(gpa, &f.engine, args, "const x: string = \"ok\";");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_clean), r.code);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.clean);
    try std.testing.expectEqualStrings("ts", parsed.value.language);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.diagnostics.len);
}

test "cli: violation exits 2" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{"--lang=ts"};
    const r = try runCli(gpa, &f.engine, args, "const x = (foo[0] as any).bar;");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_violations), r.code);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.clean);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.diagnostics.len);
    try std.testing.expectEqualStrings("no-as-any", parsed.value.diagnostics[0].rule_id);
    try std.testing.expectEqualStrings("as any is not allowed", parsed.value.diagnostics[0].message);
    try std.testing.expectEqualStrings("error", parsed.value.diagnostics[0].severity);
    try std.testing.expectEqual(false, parsed.value.diagnostics[0].demoted);
    try std.testing.expectEqualStrings("stable", parsed.value.diagnostics[0].maturity);
    try std.testing.expectEqualStrings("f8442f8df97b699227020f1ca99a3d34007e51a6f4a3934089158471a8f2963b", parsed.value.diagnostics[0].fingerprint);
}

test "cli: --filename infers language" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{"--filename=/tmp/foo.tsx"};
    const r = try runCli(gpa, &f.engine, args, "const x = foo as any;");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_violations), r.code);

    const parsed = try std.json.parseFromSlice(Report, gpa, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tsx", parsed.value.language);
}

test "cli: missing --lang exits usage (64)" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{};
    const r = try runCli(gpa, &f.engine, args, "x");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_usage), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "missing --lang") != null);
}

test "cli: unsupported --lang exits internal (70)" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{"--lang=python"};
    const r = try runCli(gpa, &f.engine, args, "print('hi')");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_internal_error), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unsupported language") != null);
}

test "cli: unknown extension exits usage (64)" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa);
    defer f.deinit();

    const args: []const [:0]const u8 = &.{"--filename=foo.rs"};
    const r = try runCli(gpa, &f.engine, args, "fn main() {}");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, cli.exit_usage), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot infer language") != null);
}

test "parseSubcommand: bare command runs the daemon without a root" {
    const sub = cli.parseSubcommand(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), sub.daemon);
}

test "parseSubcommand: 'daemon' without flags has no root" {
    const sub = cli.parseSubcommand(&.{"daemon"});
    try std.testing.expectEqual(@as(?[]const u8, null), sub.daemon);
}

test "parseSubcommand: 'daemon --root <dir>' captures the root" {
    const sub = cli.parseSubcommand(&.{ "daemon", "--root", "/proj" });
    try std.testing.expectEqualStrings("/proj", sub.daemon.?);
}

test "parseSubcommand: 'daemon --root=<dir>' captures the root" {
    const sub = cli.parseSubcommand(&.{ "daemon", "--root=/proj" });
    try std.testing.expectEqualStrings("/proj", sub.daemon.?);
}

test "parseSubcommand: 'check' with no target defaults to '.'" {
    const sub = cli.parseSubcommand(&.{"check"});
    try std.testing.expectEqualStrings(".", sub.check.target);
    try std.testing.expectEqual(reports.Format.pretty, sub.check.format);
    try std.testing.expectEqual(@as(?[]const u8, null), sub.check.baseline);
}

test "parseSubcommand: 'check --baseline <ref>' captures the ref and target" {
    const sub = cli.parseSubcommand(&.{ "check", "--baseline", "HEAD", "src/" });
    try std.testing.expectEqualStrings("HEAD", sub.check.baseline.?);
    try std.testing.expectEqualStrings("src/", sub.check.target);
}

test "parseSubcommand: 'check --baseline=<ref>' captures the ref" {
    const sub = cli.parseSubcommand(&.{ "check", "--baseline=main", "src/" });
    try std.testing.expectEqualStrings("main", sub.check.baseline.?);
    try std.testing.expectEqualStrings("src/", sub.check.target);
}

test "parseSubcommand: 'check --baseline <ref>' without a target defaults to '.'" {
    const sub = cli.parseSubcommand(&.{ "check", "--baseline", "HEAD" });
    try std.testing.expectEqualStrings("HEAD", sub.check.baseline.?);
    try std.testing.expectEqualStrings(".", sub.check.target);
}

test "baselineRef: flag wins over the environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("KATA_BASELINE", "env-ref");

    try std.testing.expectEqualStrings("env-ref", cli.baselineRef(null, &env).?);
    try std.testing.expectEqualStrings("flag-ref", cli.baselineRef("flag-ref", &env).?);
}

test "baselineRef: null without flag or environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), cli.baselineRef(null, &env));
}

test "parseSubcommand: 'check' with an explicit target" {
    const sub = cli.parseSubcommand(&.{ "check", "src/" });
    try std.testing.expectEqualStrings("src/", sub.check.target);
    try std.testing.expectEqual(reports.Format.pretty, sub.check.format);
}

test "parseSubcommand: 'check --json' selects the json format" {
    const sub = cli.parseSubcommand(&.{ "check", "--json", "src/" });
    try std.testing.expectEqualStrings("src/", sub.check.target);
    try std.testing.expectEqual(reports.Format.json, sub.check.format);
}

test "parseSubcommand: 'check --text' selects the text format" {
    const sub = cli.parseSubcommand(&.{ "check", "src/", "--text" });
    try std.testing.expectEqual(reports.Format.text, sub.check.format);
}

test "parseSubcommand: the last format flag wins" {
    const sub = cli.parseSubcommand(&.{ "check", "--json", "--text", "src/" });
    try std.testing.expectEqual(reports.Format.text, sub.check.format);
}

test "parseSubcommand: 'check --sarif' selects the sarif format" {
    const sub = cli.parseSubcommand(&.{ "check", "--sarif", "src/" });
    try std.testing.expectEqual(reports.Format.sarif, sub.check.format);
}

test "parseSubcommand: sarif wins as the last format flag" {
    const sub = cli.parseSubcommand(&.{ "check", "--json", "--sarif", "src/" });
    try std.testing.expectEqual(reports.Format.sarif, sub.check.format);
}

test "parseSubcommand: 'query --sarif' selects the sarif format" {
    const sub = cli.parseSubcommand(&.{ "query", "(comment) @match", "--sarif", "--lang=ts" });
    try std.testing.expectEqual(reports.Format.sarif, sub.query.format);
    try std.testing.expectEqual(@as(?[]const u8, null), sub.query.invalid_arg);
}

test "parseSubcommand: 'query --json' selects the json format" {
    const sub = cli.parseSubcommand(&.{ "query", "(comment) @match", "--json", "--lang=ts" });
    try std.testing.expectEqual(reports.Format.json, sub.query.format);
    try std.testing.expectEqual(@as(?[]const u8, null), sub.query.invalid_arg);
}

test "parseSubcommand: 'facts' with an explicit target" {
    const sub = cli.parseSubcommand(&.{ "facts", "src/app.ts" });
    try std.testing.expectEqualStrings("src/app.ts", sub.facts);
}

test "parseSubcommand: 'facts' without a target captures an empty path" {
    const sub = cli.parseSubcommand(&.{"facts"});
    try std.testing.expectEqualStrings("", sub.facts);
}

test "parseSubcommand: 'test' with a rules dir" {
    const sub = cli.parseSubcommand(&.{ "test", "rules" });
    try std.testing.expectEqualStrings("rules", sub.rule_test);
}

test "parseSubcommand: 'test' without a target captures an empty dir" {
    const sub = cli.parseSubcommand(&.{"test"});
    try std.testing.expectEqualStrings("", sub.rule_test);
}

test "parseSubcommand: 'query' captures the text and defaults the target" {
    const sub = cli.parseSubcommand(&.{ "query", "(comment) @match" });
    try std.testing.expectEqualStrings("(comment) @match", sub.query.text);
    try std.testing.expectEqualStrings(".", sub.query.target);
    try std.testing.expectEqualStrings("", sub.query.lang);
    try std.testing.expectEqual(@as(?[]const u8, null), sub.query.invalid_arg);
}

test "parseSubcommand: 'query' with a target and --lang" {
    const sub = cli.parseSubcommand(&.{ "query", "(comment) @match", "src/", "--lang=ts" });
    try std.testing.expectEqualStrings("(comment) @match", sub.query.text);
    try std.testing.expectEqualStrings("src/", sub.query.target);
    try std.testing.expectEqualStrings("ts", sub.query.lang);
}

test "parseSubcommand: 'query' accepts --lang before the text" {
    const sub = cli.parseSubcommand(&.{ "query", "--lang", "go", "(comment) @match" });
    try std.testing.expectEqualStrings("(comment) @match", sub.query.text);
    try std.testing.expectEqualStrings("go", sub.query.lang);
}

test "parseSubcommand: 'query' flags an extra positional" {
    const sub = cli.parseSubcommand(&.{ "query", "((comment)", "@match)", "src/", "--lang=ts" });
    try std.testing.expectEqualStrings("src/", sub.query.invalid_arg.?);
}

test "parseSubcommand: 'query' flags an unknown flag" {
    const sub = cli.parseSubcommand(&.{ "query", "(comment) @match", "--verbose" });
    try std.testing.expectEqualStrings("--verbose", sub.query.invalid_arg.?);
}

test "parseSubcommand: 'stop' is recognised" {
    const sub = cli.parseSubcommand(&.{"stop"});
    try std.testing.expectEqual(cli.Subcommand.stop, sub);
}

test "parseSubcommand: 'new-rule' is recognised" {
    const sub = cli.parseSubcommand(&.{ "new-rule", "ts", "no-foo" });
    try std.testing.expectEqual(cli.Subcommand.new_rule, sub);
}

test "parseSubcommand: a flag dispatches to one-shot" {
    const sub = cli.parseSubcommand(&.{"--lang=ts"});
    try std.testing.expectEqual(cli.Subcommand.one_shot, sub);
}

test "parseSubcommand: an unknown subcommand is captured, not run as daemon" {
    const sub = cli.parseSubcommand(&.{"typo-here"});
    try std.testing.expectEqualStrings("typo-here", sub.unknown);
}

test "parseSubcommand: 'check --fix' selects safe fix application" {
    const sub = cli.parseSubcommand(&.{ "check", "--fix", "src/" });
    try std.testing.expectEqual(check.FixLevel.safe, sub.check.fix);
}

test "parseSubcommand: 'check --fix-unsafe' selects unsafe fix application" {
    const sub = cli.parseSubcommand(&.{ "check", "--fix-unsafe", "src/" });
    try std.testing.expectEqual(check.FixLevel.unsafe, sub.check.fix);
}

test "parseSubcommand: check without fix flags applies nothing" {
    const sub = cli.parseSubcommand(&.{ "check", "src/" });
    try std.testing.expectEqual(check.FixLevel.off, sub.check.fix);
}

test "socketPath: KATA_SOCKET override wins verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try args_mod.socketPath(arena.allocator(), "/custom/kata.sock", "/run/user/1000", 42);

    try std.testing.expectEqualStrings("/custom/kata.sock", path);
}

test "socketPath: runtime dir yields a version and mtime stamped name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try args_mod.socketPath(arena.allocator(), null, "/run/user/1000", 42);
    const expected = try std.fmt.allocPrint(arena.allocator(), "/run/user/1000/kata-{s}-42.sock", .{build_options.version});

    try std.testing.expectEqualStrings(expected, path);
}

test "socketPath: falls back to /tmp with the same stamped name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try args_mod.socketPath(arena.allocator(), null, null, 42);
    const expected = try std.fmt.allocPrint(arena.allocator(), "/tmp/kata-{s}-42.sock", .{build_options.version});

    try std.testing.expectEqualStrings(expected, path);
}

test "socketPath: different binary mtimes yield different paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = try args_mod.socketPath(arena.allocator(), null, null, 1);
    const second = try args_mod.socketPath(arena.allocator(), null, null, 2);

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "parseSubcommand: '--version' selects the version command" {
    const sub = cli.parseSubcommand(&.{"--version"});
    try std.testing.expectEqual(cli.Subcommand.version, sub);
}

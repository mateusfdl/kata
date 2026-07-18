const std = @import("std");
const cli = @import("cli.zig");
const reports = @import("reports.zig");
const test_fixture = @import("test_fixture.zig");

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
        maturity: []const u8,
        fingerprint: []const u8,
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

const std = @import("std");
const cli = @import("cli.zig");
const engine_mod = @import("engine.zig");
const test_fixture = @import("test_fixture.zig");

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
    engine: *engine_mod.Engine,
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

test "parseSubcommand: bare command runs the daemon" {
    const sub = cli.parseSubcommand(&.{});
    try std.testing.expectEqual(cli.Subcommand.daemon, sub);
}

test "parseSubcommand: 'check' with no target defaults to '.'" {
    const sub = cli.parseSubcommand(&.{"check"});
    try std.testing.expectEqualStrings(".", sub.check);
}

test "parseSubcommand: 'check' with an explicit target" {
    const sub = cli.parseSubcommand(&.{ "check", "src/" });
    try std.testing.expectEqualStrings("src/", sub.check);
}

test "parseSubcommand: 'stop' is recognised" {
    const sub = cli.parseSubcommand(&.{"stop"});
    try std.testing.expectEqual(cli.Subcommand.stop, sub);
}

test "parseSubcommand: a flag dispatches to one-shot" {
    const sub = cli.parseSubcommand(&.{"--lang=ts"});
    try std.testing.expectEqual(cli.Subcommand.one_shot, sub);
}

test "parseSubcommand: an unknown subcommand is captured, not run as daemon" {
    const sub = cli.parseSubcommand(&.{"typo-here"});
    try std.testing.expectEqualStrings("typo-here", sub.unknown);
}

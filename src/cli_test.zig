const std = @import("std");

const build_options = @import("build_options");

const cli = @import("cli.zig");
const test_fixture = @import("test_fixture.zig");

const Exit = @import("cli/exit.zig").Exit;
const TestEnv = @import("cli/test_env.zig").TestEnv;

const usage_check = "usage: kata check [path] [--json|--text|--sarif] [--fix|--fix-unsafe] [--baseline <ref>]\n";
const usage_daemon = "usage: kata daemon [--root <dir>]\n";
const usage_facts = "usage: kata facts <file>\n";
const usage_test = "usage: kata test <rules-dir>\n";
const usage_query = "usage: kata query '<kata rule>' [path] --lang <ts|tsx|go|zig> [--json|--text|--sarif]\n";
const usage_stop = "usage: kata stop\n";
const usage_new_rule = "usage: kata new-rule <ts|tsx|go|zig> <rule-id>\n";
const usage_lint_stdin = "usage: kata --lang <ts|tsx|go|zig> [--filename <path>] < source\n" ++
    "usage: kata --filename <path> < source  (infer language from the file extension)\n";

const usage_all = "usage: kata  (same as kata daemon)\n" ++ usage_daemon ++ usage_check ++ usage_facts ++ usage_test ++ usage_query ++
    usage_stop ++ usage_new_rule ++ usage_lint_stdin ++ "usage: kata --version\nusage: kata --help\n";

test "dispatch: help prints usage on stdout before validation or execution" {
    const Case = struct { argv: []const [:0]const u8, usage: []const u8 };
    for ([_]Case{
        .{ .argv = &.{"--help"}, .usage = usage_all },
        .{ .argv = &.{ "check", "--help" }, .usage = usage_check },
        .{ .argv = &.{ "query", "--help" }, .usage = usage_query },
        .{ .argv = &.{ "daemon", "--root", "missing", "--help" }, .usage = usage_daemon },
        .{ .argv = &.{ "--lang=go", "--help" }, .usage = usage_lint_stdin },
    }) |case| {
        var t: TestEnv = .init("");
        defer t.deinit();

        try std.testing.expectEqual(Exit.clean, try cli.dispatch(t.env(), case.argv));
        try std.testing.expectEqualStrings(case.usage, t.out.written());
        try std.testing.expectEqualStrings("", t.err.written());
    }
}

fn expectUsageError(expected_stderr: []const u8, argv: []const [:0]const u8) !void {
    var t: TestEnv = .init("");
    defer t.deinit();

    try std.testing.expectError(error.UsageReported, cli.dispatch(t.env(), argv));
    try std.testing.expectEqualStrings(expected_stderr, t.err.written());
    try std.testing.expectEqualStrings("", t.out.written());
}

test "dispatch: --version prints the build version" {
    var t: TestEnv = .init("");
    defer t.deinit();

    try std.testing.expectEqual(Exit.clean, try cli.dispatch(t.env(), &.{"--version"}));
    try std.testing.expectEqualStrings(build_options.version ++ "\n", t.out.written());
}

test "dispatch: only a leading --version takes precedence over the other arguments" {
    var t: TestEnv = .init("");
    defer t.deinit();

    try std.testing.expectEqual(Exit.clean, try cli.dispatch(t.env(), &.{ "--version", "check", "--unknown" }));
    try std.testing.expectEqualStrings(build_options.version ++ "\n", t.out.written());
    try std.testing.expectEqualStrings("", t.err.written());

    try expectUsageError("kata check: unexpected argument \"--version\"\n" ++ usage_check, &.{ "check", "--version" });
    try expectUsageError("kata: unexpected argument \"--version\"\n" ++ usage_lint_stdin, &.{ "--lang=go", "--version" });
}

test "dispatch: an unknown subcommand lists the usage of every command" {
    try expectUsageError(
        "unknown subcommand: \"bogus\"\n" ++ usage_all,
        &.{"bogus"},
    );
}

test "dispatch: an unexpected argument names the command and shows its usage" {
    try expectUsageError("kata check: unexpected argument \"--format\"\n" ++ usage_check, &.{ "check", "--format", "json" });
    try expectUsageError("kata check: unexpected argument \"b.ts\"\n" ++ usage_check, &.{ "check", "a.ts", "b.ts" });
    try expectUsageError("kata daemon: unexpected argument \"extra\"\n" ++ usage_daemon, &.{ "daemon", "extra" });
    try expectUsageError("kata facts: unexpected argument \"--lang\"\n" ++ usage_facts, &.{ "facts", "--lang", "ts" });
    try expectUsageError("kata test: unexpected argument \"--verbose\"\n" ++ usage_test, &.{ "test", "--verbose" });
    try expectUsageError("kata stop: unexpected argument \"now\"\n" ++ usage_stop, &.{ "stop", "now" });
    try expectUsageError("kata new-rule: unexpected argument \"extra\"\n" ++ usage_new_rule, &.{ "new-rule", "ts", "id", "extra" });
}

test "dispatch: an unquoted query shows the quoted usage" {
    try expectUsageError(
        "kata query: unexpected argument \"@match)\"\n" ++ usage_query,
        &.{ "query", "((comment)", ".", "@match)", "--lang=ts" },
    );
}

test "dispatch: a flag without its value names the flag" {
    try expectUsageError("kata check: \"--baseline\" requires a value\n" ++ usage_check, &.{ "check", "--baseline" });
    try expectUsageError("kata check: \"--baseline\" requires a value\n" ++ usage_check, &.{ "check", "--baseline", "--json", "src/" });
    try expectUsageError("kata daemon: \"--root\" requires a value\n" ++ usage_daemon, &.{ "daemon", "--root" });
    try expectUsageError("kata query: \"--lang\" requires a value\n" ++ usage_query, &.{ "query", "rule", "--lang" });
}

test "dispatch: a missing required argument shows the usage" {
    try expectUsageError(usage_facts, &.{"facts"});
    try expectUsageError(usage_test, &.{"test"});
    try expectUsageError(usage_query, &.{ "query", "--lang=ts" });
    try expectUsageError(usage_new_rule, &.{ "new-rule", "ts" });
}

test "dispatch: a leading flag selects stdin linting" {
    try expectUsageError("kata: unexpected argument \"--bogus\"\n" ++ usage_lint_stdin, &.{ "--lang=ts", "--bogus" });
    try expectUsageError("kata: unexpected argument \"a.ts\"\n" ++ usage_lint_stdin, &.{ "--lang=ts", "a.ts" });
    try expectUsageError("cannot infer language from extension \".rs\"\n", &.{"--filename=main.rs"});
}

test "dispatch: valid arguments reach the command" {
    try expectUsageError("unknown language: \"rust\" (expected ts, tsx, go, or zig)\n", &.{ "new-rule", "rust", "no-unsafe" });
    try expectUsageError("kata query: --lang is required (expected ts, tsx, go, or zig)\n", &.{ "query", "rule" });
}

test "dispatch: a clean cache entry cannot cross languages for the same input" {
    const io = std.testing.io;
    var project = try test_fixture.TmpProject.init();
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, ".kata");
    try project.tmp.dir.writeFile(io, .{ .sub_path = ".kata/rules.yaml", .data = "cache: true\nrules:\n  ts:\n    no-as-any:\n" });

    const source = "const x = foo as any;\n";
    var go: TestEnv = .init(source);
    defer go.deinit();
    const filename = try go.arena.allocator().dupeZ(u8, try project.path("a.ts"));
    const cache = try project.path("cache");
    const socket = try project.path("absent.sock");
    try go.environ.put("XDG_CACHE_HOME", cache);
    try go.environ.put("KATA_SOCKET", socket);
    try std.testing.expectEqual(Exit.clean, try cli.dispatch(go.env(), &.{ "--lang=go", "--filename", filename }));
    try std.testing.expectEqualStrings("", go.err.written());

    var ts: TestEnv = .init(source);
    defer ts.deinit();
    try ts.environ.put("XDG_CACHE_HOME", cache);
    try ts.environ.put("KATA_SOCKET", socket);
    try std.testing.expectEqual(Exit.violations, try cli.dispatch(ts.env(), &.{ "--lang=ts", "--filename", filename }));
    try std.testing.expectEqualStrings("", ts.err.written());

    var uncached: TestEnv = .init(source);
    defer uncached.deinit();
    try uncached.environ.put("KATA_SOCKET", socket);
    try std.testing.expectEqual(Exit.violations, try cli.dispatch(uncached.env(), &.{ "--lang=ts", "--filename", filename }));
    try std.testing.expectEqualStrings(uncached.out.written(), ts.out.written());
}

test "dispatch: baseline settings for TSX do not demote new TypeScript errors" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var project = try test_fixture.TmpProject.init();
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, ".kata");
    try project.tmp.dir.writeFile(io, .{ .sub_path = ".kata/rules.yaml", .data = "rules:\n  ts:\n    no-as-any:\n  tsx:\n    no-as-any:\n      enabled: false\n" });
    try test_fixture.runGit(gpa, io, project.tmp.dir, &.{ "git", "init", "-q" });
    try test_fixture.runGit(gpa, io, project.tmp.dir, &.{ "git", "add", "." });
    try test_fixture.runGit(gpa, io, project.tmp.dir, &.{ "git", "-c", "user.name=kata", "-c", "user.email=kata@test", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "new.ts", .data = "const x = foo as any;\n" });

    var baseline: TestEnv = .init("");
    defer baseline.deinit();
    const filename = try baseline.arena.allocator().dupeZ(u8, try project.path("new.ts"));
    try std.testing.expectEqual(Exit.violations, try cli.dispatch(baseline.env(), &.{ "check", filename, "--text", "--baseline", "HEAD" }));
    try std.testing.expectEqualStrings("", baseline.err.written());

    var absolute: TestEnv = .init("");
    defer absolute.deinit();
    try std.testing.expectEqual(Exit.violations, try cli.dispatch(absolute.env(), &.{ "check", filename, "--text" }));
    try std.testing.expectEqualStrings(absolute.out.written(), baseline.out.written());
}

test "dispatch: daemon root loads project rules before starting the server" {
    const io = std.testing.io;
    var project = try test_fixture.TmpProject.init();
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, ".kata/rules/project");
    try project.tmp.dir.writeFile(io, .{ .sub_path = ".kata/rules.yaml", .data = "rules:\n  project:\n    review-import:\n" });
    try project.tmp.dir.writeFile(io, .{ .sub_path = ".kata/rules/project/review-import.kata", .data =
        \\rule review-import {
        \\  kind project
        \\  match import @i
        \\  emit @i { message "import found" }
        \\}
    });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "export const x = 1;\n" });

    var t: TestEnv = .init("");
    defer t.deinit();
    const arena = t.arena.allocator();
    const root = try arena.dupeZ(u8, project.root);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const socket = try std.fs.path.resolve(arena, &.{ cwd, try project.path("daemon.sock") });
    try t.environ.put("KATA_SOCKET", socket);
    const address = try std.Io.net.UnixAddress.init(socket);
    var listening = try address.listen(io, .{});
    defer listening.deinit(io);

    try std.testing.expectEqual(Exit.clean, try cli.dispatch(t.env(), &.{ "daemon", "--root", root }));
    try std.testing.expectEqualStrings("kata daemon already running\n", t.err.written());
    try std.testing.expectEqualStrings("", t.out.written());
}

const std = @import("std");
const cli = @import("root.zig");

const Format = enum { pretty, json, text };

const Build = struct {
    target: []const u8 = ".",
    format: Format = .pretty,
};

const Fetch = struct {
    url: []const u8,
    token: []const u8,
};

const Stdin = struct { lang: ?[]const u8 = null };

const Ran = union(enum) {
    help,
    version,
    build: Build,
    fetch: Fetch,
    stdin: Stdin,
};

fn runBuild(_: void, options: Build) !Ran {
    return .{ .build = options };
}

fn runFetch(_: void, options: Fetch) !Ran {
    return .{ .fetch = options };
}

fn runStdin(_: void, options: Stdin) !Ran {
    return .{ .stdin = options };
}

fn runVersion(_: void) !Ran {
    return .version;
}

const build = cli.command(Build, .{
    .name = "build",
    .positionals = .{.{ .field = .target, .label = "path" }},
    .flags = .{
        .{ .name = "json", .field = .format, .value = .json },
        .{ .name = "text", .field = .format, .value = .text },
    },
    .run = runBuild,
});

const fetch = cli.command(Fetch, .{
    .name = "fetch",
    .positionals = .{.{ .field = .url, .label = "<url>" }},
    .flags = .{.{ .name = "token", .field = .token, .label = "<secret>", .hint = " (see TOOL_TOKEN)" }},
    .run = runFetch,
});

const lang_flag = .{ .name = "lang", .field = .lang, .label = "<name>" };

const stdin = cli.command(Stdin, .{
    .name = "",
    .flags = .{lang_flag},
    .usage_forms = .{
        "[" ++ cli.flagLabel(lang_flag) ++ "] < source",
        "< source  (guess the language)",
    },
    .run = runStdin,
});

const tool = cli.app(Ran, .{
    .name = "tool",
    .help_result = Ran.help,
    .commands = .{ build, fetch },
    .default = build,
    .root = stdin,
    .leading_flags = .{.{ .name = "version", .run = runVersion }},
});

const usage_build = "usage: tool build [path] [--json|--text]\n";
const usage_fetch = "usage: tool fetch <url> --token <secret>\n";
const usage_stdin = "usage: tool [--lang <name>] < source\nusage: tool < source  (guess the language)\n";
const usage_all = "usage: tool  (same as tool build)\n" ++ usage_build ++ usage_fetch ++ usage_stdin ++
    "usage: tool --version\nusage: tool --help\n";

const Expected = struct {
    result: anyerror!Ran,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

fn expectDispatch(expected: Expected, argv: []const [:0]const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    try std.testing.expectEqualDeep(expected.result, tool.dispatch({}, &out.writer, &err.writer, argv));
    try std.testing.expectEqualStrings(expected.stdout, out.written());
    try std.testing.expectEqualStrings(expected.stderr, err.written());
}

fn expectUsageError(stderr: []const u8, argv: []const [:0]const u8) !void {
    try expectDispatch(.{ .result = error.UsageReported, .stderr = stderr }, argv);
}

test "dispatch: no arguments run the default command" {
    try expectDispatch(.{ .result = .{ .build = .{} } }, &.{});
}

test "dispatch: the first word selects a command that parses the other arguments" {
    try expectDispatch(.{ .result = .{ .build = .{ .target = "src", .format = .json } } }, &.{ "build", "src", "--json" });
    try expectDispatch(
        .{ .result = .{ .fetch = .{ .url = "host", .token = "abc" } } },
        &.{ "fetch", "--token=abc", "host" },
    );
}

test "dispatch: a leading flag runs alone" {
    try expectDispatch(.{ .result = .version }, &.{"--version"});
}

test "dispatch: other flags in the first position go to the root command" {
    try expectDispatch(.{ .result = .{ .stdin = .{ .lang = "go" } } }, &.{ "--lang", "go" });
}

test "dispatch: '--help' in the first position prints the usage of all commands" {
    try expectDispatch(.{ .result = .help, .stdout = usage_all }, &.{"--help"});
}

test "dispatch: '--help' after a command prints the usage of that command" {
    try expectDispatch(.{ .result = .help, .stdout = usage_build }, &.{ "build", "src", "--help" });
    try expectDispatch(.{ .result = .help, .stdout = usage_fetch }, &.{ "fetch", "--help" });
    try expectDispatch(.{ .result = .help, .stdout = usage_stdin }, &.{ "--lang", "--help" });
}

test "dispatch: an unknown command reports the usage of all commands" {
    try expectUsageError("unknown subcommand: \"deploy\"\n" ++ usage_all, &.{"deploy"});
}

test "dispatch: an unexpected argument reports the command usage" {
    try expectUsageError("tool build: unexpected argument \"extra\"\n" ++ usage_build, &.{ "build", "src", "extra" });
    try expectUsageError("tool: unexpected argument \"--bogus\"\n" ++ usage_stdin, &.{"--bogus"});
}

test "dispatch: a flag without its value reports the command usage" {
    try expectUsageError("tool fetch: \"--token\" requires a value\n" ++ usage_fetch, &.{ "fetch", "host", "--token" });
}

test "dispatch: a missing required flag reports the flag and its hint" {
    try expectUsageError("tool fetch: --token is required (see TOOL_TOKEN)\n", &.{ "fetch", "host" });
}

test "dispatch: a missing required positional reports only the command usage" {
    try expectUsageError(usage_fetch, &.{ "fetch", "--token=abc" });
}

const Key = struct { key: []const u8 };

fn runKey(_: void, _: Key) !void {}

test "dispatch prints literal braces in help and diagnostics" {
    const root = cli.command(Key, .{
        .name = "",
        .positionals = .{.{ .field = .key, .label = "<{key}>" }},
        .run = runKey,
    });
    const app = cli.app(void, .{ .name = "tool", .commands = .{}, .default = root, .root = root, .help_result = {} });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    try app.dispatch({}, &out.writer, &err.writer, &.{"--help"});

    try std.testing.expectEqualStrings("usage: tool <{key}>\nusage: tool --help\n", out.written());
    try std.testing.expectEqualStrings("", err.written());

    try std.testing.expectError(error.UsageReported, app.dispatch({}, &out.writer, &err.writer, &.{}));
    try std.testing.expectEqualStrings("usage: tool <{key}>\n", err.written());
}

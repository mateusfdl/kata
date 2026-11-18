const std = @import("std");

const new_rule = @import("new_rule.zig");
const test_fixture = @import("../test_fixture.zig");

const Exit = @import("exit.zig").Exit;
const TestEnv = @import("test_env.zig").TestEnv;

const rule_path = "kata/rules/ts/no-throw-literal.kata";

const Home = struct {
    tmp: std.testing.TmpDir,
    t: TestEnv,

    fn init() !Home {
        var self: Home = .{ .tmp = std.testing.tmpDir(.{}), .t = .init("") };

        var path_buf: [256]u8 = undefined;
        try self.t.environ.put("XDG_CONFIG_HOME", try test_fixture.relativeTmpPath(&path_buf, &self.tmp.sub_path));

        return self;
    }

    fn deinit(self: *Home) void {
        self.t.deinit();
        self.tmp.cleanup();
    }

    fn read(self: *Home, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, sub_path, self.t.arena.allocator(), .limited(8 * 1024));
    }
};

test "new-rule: writes the kata template under the user rules dir" {
    var home = try Home.init();
    defer home.deinit();

    const outcome = new_rule.execute(home.t.env(), .{ .lang = "ts", .id = "no-throw-literal" });

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings(
        \\rule no-throw-literal {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match { message "TODO: explain why this is bad" }
        \\}
        \\
    , try home.read(rule_path));

    const expected = try std.fmt.allocPrint(
        home.t.arena.allocator(),
        "{s}/{s}\nadd 'no-throw-literal:' under 'rules: ts:' in rules.yaml to activate it\n",
        .{ home.t.environ.get("XDG_CONFIG_HOME").?, rule_path },
    );
    try std.testing.expectEqualStrings(expected, home.t.out.written());
}

test "new-rule: refuses to overwrite an existing rule" {
    var home = try Home.init();
    defer home.deinit();

    try home.tmp.dir.createDirPath(std.testing.io, "kata/rules/ts");
    try home.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rule_path, .data = "original\n" });

    const outcome = new_rule.execute(home.t.env(), .{ .lang = "ts", .id = "no-throw-literal" });

    try std.testing.expectError(error.UsageReported, outcome);
    const expected = try std.fmt.allocPrint(
        home.t.arena.allocator(),
        "path already exists: {s}/{s}\n",
        .{ home.t.environ.get("XDG_CONFIG_HOME").?, rule_path },
    );
    try std.testing.expectEqualStrings(expected, home.t.err.written());
    try std.testing.expectEqualStrings("original\n", try home.read(rule_path));
}

test "new-rule: rejects unknown languages without writing a file" {
    var home = try Home.init();
    defer home.deinit();

    const outcome = new_rule.execute(home.t.env(), .{ .lang = "rust", .id = "no-unsafe" });

    try std.testing.expectError(error.UsageReported, outcome);
    try std.testing.expectEqualStrings("unknown language: \"rust\" (expected ts, tsx, go, or zig)\n", home.t.err.written());
    try std.testing.expectError(error.FileNotFound, home.tmp.dir.openDir(std.testing.io, "kata", .{}));
}

test "new-rule: rejects invalid rule ids" {
    var home = try Home.init();
    defer home.deinit();

    const outcome = new_rule.execute(home.t.env(), .{ .lang = "ts", .id = "no.dots" });

    try std.testing.expectError(error.UsageReported, outcome);
    try std.testing.expectEqualStrings("invalid rule id: \"no.dots\" (must match [A-Za-z0-9_-]+)\n", home.t.err.written());
}

test "new-rule: fails clearly when no user rules dir is resolvable" {
    var t: TestEnv = .init("");
    defer t.deinit();

    const outcome = new_rule.execute(t.env(), .{ .lang = "ts", .id = "no-foo" });

    try std.testing.expectError(error.UsageReported, outcome);
    try std.testing.expectEqualStrings("cannot resolve user rules directory: set XDG_CONFIG_HOME or HOME\n", t.err.written());
}

const std = @import("std");

const lint = @import("../lint.zig");
const config = @import("config.zig");
const context = @import("context.zig");

const test_fixture = @import("../test_fixture.zig");

const language = lint.language;

const Setup = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    registry: language.Registry,
    root: []const u8,

    fn init(io: std.Io) !*Setup {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Setup);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(gpa),
            .registry = .init(),
            .root = undefined,
        };
        _ = io;
        var rel_buf: [256]u8 = undefined;
        const rel = try test_fixture.relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        self.root = try self.arena.allocator().dupe(u8, rel);
        return self;
    }

    fn deinit(self: *Setup) void {
        const gpa = std.testing.allocator;
        self.tmp.cleanup();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn path(self: *Setup, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.root, sub });
    }

    fn resolver(self: *Setup, user_dir: ?[]const u8, global: ?*const config.Config) context.Resolver {
        return .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .registry = &self.registry,
            .user_rules_dir = user_dir,
            .global_config = global,
        };
    }
};

fn ruleSource(set: anytype, lang: language.Name, id: []const u8) ?[]const u8 {
    for (set.get(lang)) |r| {
        if (std.mem.eql(u8, r.id, id)) return r.source;
    }
    return null;
}

test "context: no anchor resolves the global context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/my-user-rule.scm", .data = "((identifier) @match)" });

    var r = s.resolver(try s.path("user"), null);
    const ctx = try r.resolve(null);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ctx.root);
    try std.testing.expectEqualStrings("((identifier) @match)", ruleSource(&ctx.rule_set, .ts, "my-user-rule").?);
    try std.testing.expectEqual(false, ctx.resolved.ratchet);
}

test "context: anchored file loads project rules on top of user rules" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/shared-rule.scm", .data = "((user_version) @match)" });
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/shared-rule.scm", .data = "((project_version) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/project-only.scm", .data = "((call_expression) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(try s.path("user"), null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expect(ctx.root != null);
    try std.testing.expect(std.mem.endsWith(u8, ctx.root.?, "proj"));
    try std.testing.expectEqualStrings("((project_version) @match)", ruleSource(&ctx.rule_set, .ts, "shared-rule").?);
    try std.testing.expectEqualStrings("((call_expression) @match)", ruleSource(&ctx.rule_set, .ts, "project-only").?);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.warnings.items.len);
}

test "context: project rules.yaml overrides global config per key" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/drop-me.scm", .data = "((identifier) @match)" });
    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\ndisabled:\n  - ts/drop-me\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var diag: config.Diagnostic = .{};
    var global = try config.parse(std.testing.allocator, "metrics:\n  complexity: 10\n", &diag);
    defer global.deinit();

    var r = s.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqual(true, ctx.resolved.ratchet);
    try std.testing.expectEqual(@as(?u32, 10), ctx.resolved.metrics.get(.complexity));
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&ctx.rule_set, .ts, "drop-me"));
}

test "context: project without rules dir or rules.yaml keeps global behavior" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var diag: config.Diagnostic = .{};
    var global = try config.parse(std.testing.allocator, "ratchet: true\n", &diag);
    defer global.deinit();

    var r = s.resolver(null, &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expect(ctx.root != null);
    try std.testing.expectEqual(true, ctx.resolved.ratchet);
}

test "context: anchor outside any project falls back to global config" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    var diag: config.Diagnostic = .{};
    var global = try config.parse(std.testing.allocator, "ratchet: true\n", &diag);
    defer global.deinit();

    var r = s.resolver(null, &global);
    const ctx = try r.resolve("/kata-context-test-absent/pkg/main.go");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ctx.root);
    try std.testing.expectEqual(true, ctx.resolved.ratchet);
}

test "context: malformed project rules.yaml surfaces the parse error" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "nonsense: true\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const got = r.resolve(try s.path("proj/src/main.ts"));
    try std.testing.expectError(error.UnknownTopLevelKey, got);
    try std.testing.expectEqual(@as(u32, 1), r.diag.line);
}

test "cache: no anchor yields no project context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?*context.Context, null), try cache.acquire(s.arena.allocator(), null));
}

test "cache: anchor outside any project yields no project context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?*context.Context, null), try cache.acquire(s.arena.allocator(), "/kata-context-test-absent/pkg/main.go"));
}

test "cache: same project resolves once and is reused" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.scm", .data = "((identifier) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/b.ts", .data = "const b = 2;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/a.ts"))).?;
    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/b.ts"))).?;

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("((identifier) @match)", ruleSource(&first.rule_set, .ts, "local").?);
}

test "cache: distinct projects get their own contexts" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "one/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "two/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/.kata/rules/ts/rule-one.scm", .data = "((one) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/.kata/rules/ts/rule-two.scm", .data = "((two) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/b.ts", .data = "const b = 2;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const one = (try cache.acquire(s.arena.allocator(), try s.path("one/a.ts"))).?;
    const two = (try cache.acquire(s.arena.allocator(), try s.path("two/b.ts"))).?;

    try std.testing.expect(one != two);
    try std.testing.expectEqualStrings("((one) @match)", ruleSource(&one.rule_set, .ts, "rule-one").?);
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&one.rule_set, .ts, "rule-two"));
    try std.testing.expectEqualStrings("((two) @match)", ruleSource(&two.rule_set, .ts, "rule-two").?);
}

test "cache: unchanged project keeps serving the cached context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.scm", .data = "((identifier) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(first, second);
}

test "cache: edited rule file rebuilds the project context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.scm", .data = "((old_body) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings("((old_body) @match)", ruleSource(&first.rule_set, .ts, "local").?);

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.scm", .data = "((new_body_longer) @match)" });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings("((new_body_longer) @match)", ruleSource(&second.rule_set, .ts, "local").?);
}

test "cache: added rule file rebuilds the project context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/one.scm", .data = "((one) @match)" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&first.rule_set, .ts, "two"));

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/two.scm", .data = "((two) @match)" });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings("((two) @match)", ruleSource(&second.rule_set, .ts, "two").?);
}

test "cache: deleted rules yaml rebuilds and drops project config" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = s.resolver(null, null);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(true, first.resolved.ratchet);

    try s.tmp.dir.deleteFile(io, "proj/.kata/rules.yaml");

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(false, second.resolved.ratchet);
}

const std = @import("std");

const context_cache = @import("context_cache.zig");
const test_fixture = @import("../test_fixture.zig");

const kata_one =
    \\rule one {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "one" }
    \\}
;

const kata_two =
    \\rule two {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "two" }
    \\}
;

test "cache: no anchor yields no project context" {
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    var r = test_fixture.resolver(null, null);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?*context_cache.Cache.Entry, null), try cache.acquire(s.arena.allocator(), null));
}

test "cache: anchor outside any project yields no project context" {
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    var r = test_fixture.resolver(null, null);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?*context_cache.Cache.Entry, null), try cache.acquire(s.arena.allocator(), "/kata-context-test-absent/pkg/main.go"));
}

test "cache: same project resolves once and is reused" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = test_fixture.kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/b.ts", .data = "const b = 2;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/a.ts"))).?;
    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/b.ts"))).?;

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first.ctx, second.ctx);
    try std.testing.expectEqualStrings(test_fixture.kata_ident, test_fixture.ruleSource(&first.ctx.rule_set, .ts, "local").?);
}

test "cache: distinct projects get their own contexts" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "one/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "two/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/.kata/rules/ts/rule-one.kata", .data = kata_one });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/.kata/rules/ts/rule-two.kata", .data = kata_two });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/b.ts", .data = "const b = 2;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    rule-one:\n    rule-two:\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const one = (try cache.acquire(s.arena.allocator(), try s.path("one/a.ts"))).?;
    const two = (try cache.acquire(s.arena.allocator(), try s.path("two/b.ts"))).?;

    try std.testing.expect(one != two);
    try std.testing.expectEqualStrings(kata_one, test_fixture.ruleSource(&one.ctx.rule_set, .ts, "rule-one").?);
    try std.testing.expectEqual(@as(?[]const u8, null), test_fixture.ruleSource(&one.ctx.rule_set, .ts, "rule-two"));
    try std.testing.expectEqualStrings(kata_two, test_fixture.ruleSource(&two.ctx.rule_set, .ts, "rule-two").?);
}

test "cache: unchanged project keeps serving the cached context" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = test_fixture.kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = test_fixture.resolver(null, null);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    const first_ctx = first.ctx;
    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first_ctx, second.ctx);
}

test "cache: edited rule file rebuilds the project context" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = test_fixture.kata_local_old });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(test_fixture.kata_local_old, test_fixture.ruleSource(&first.ctx.rule_set, .ts, "local").?);

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = test_fixture.kata_local_new });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(test_fixture.kata_local_new, test_fixture.ruleSource(&second.ctx.rule_set, .ts, "local").?);
}

test "cache: added rule file rebuilds the project context" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/one.kata", .data = kata_one });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    one:\n    two:\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(@as(?[]const u8, null), test_fixture.ruleSource(&first.ctx.rule_set, .ts, "two"));

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/two.kata", .data = kata_two });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(kata_two, test_fixture.ruleSource(&second.ctx.rule_set, .ts, "two").?);
}

test "cache: deleted rules yaml rebuilds and drops project config" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var r = test_fixture.resolver(null, null);
    var cache = context_cache.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(true, first.ctx.resolved.ratchet);

    try s.tmp.dir.deleteFile(io, "proj/.kata/rules.yaml");

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(false, second.ctx.resolved.ratchet);
}

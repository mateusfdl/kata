const std = @import("std");

const lint = @import("engine");
const config = @import("config.zig");
const context = @import("context.zig");

const test_fixture = @import("../test_fixture.zig");

const language = lint.language;

const kata_ident =
    \\rule marker {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "flag" }
    \\}
;

const kata_shared_user =
    \\rule shared-rule {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "user" }
    \\}
;

const kata_shared_project =
    \\rule shared-rule {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "project" }
    \\}
;

const kata_project_only =
    \\rule project-only {
    \\  lang ts
    \\  match call_expression @match
    \\  emit @match { message "call" }
    \\}
;

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

const kata_local_old =
    \\rule local {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "old" }
    \\}
;

const kata_local_new =
    \\rule local {
    \\  lang ts
    \\  match identifier @match
    \\  emit @match { message "new body, strictly longer than the old one" }
    \\}
;

const Setup = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(io: std.Io) !*Setup {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Setup);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(gpa),
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

    fn resolver(_: *Setup, user_dir: ?[]const u8, global: ?*const config.Config) context.Resolver {
        return .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .user_rules_dir = user_dir,
            .global_config = global,
        };
    }
};

fn parseGlobal(yaml: []const u8) !config.Config {
    var diag: config.Diagnostic = .{};
    return try config.parse(std.testing.allocator, yaml, &diag);
}

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
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/my-user-rule.kata", .data = kata_ident });

    var global = try parseGlobal("rules:\n  ts:\n    my-user-rule:\n");
    defer global.deinit();

    var r = s.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(null);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ctx.root);
    try std.testing.expectEqualStrings(kata_ident, ruleSource(&ctx.rule_set, .ts, "my-user-rule").?);
    try std.testing.expectEqual(false, ctx.resolved.ratchet);
}

test "context: anchored file loads project rules on top of user rules" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/shared-rule.kata", .data = kata_shared_user });
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/shared-rule.kata", .data = kata_shared_project });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/project-only.kata", .data = kata_project_only });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    shared-rule:\n    project-only:\n");
    defer global.deinit();

    var r = s.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expect(ctx.root != null);
    try std.testing.expect(std.mem.endsWith(u8, ctx.root.?, "proj"));
    try std.testing.expectEqualStrings(kata_shared_project, ruleSource(&ctx.rule_set, .ts, "shared-rule").?);
    try std.testing.expectEqualStrings(kata_project_only, ruleSource(&ctx.rule_set, .ts, "project-only").?);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.warnings.items.len);
}

test "context: project rules.yaml overrides the matching global rule" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/drop-me.kata", .data = kata_ident });
    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\nrules:\n  ts:\n    drop-me:\n      enabled: false\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    drop-me:\n");
    defer global.deinit();

    var r = s.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqual(true, ctx.resolved.ratchet);
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&ctx.rule_set, .ts, "drop-me"));
}

test "context: undeclared rules stay inactive" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/undeclared.kata", .data = kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&ctx.rule_set, .ts, "undeclared"));
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.ts).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.tsx).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.go).len);
}

test "context: project rules.yaml enables its own rules" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    local:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqualStrings(kata_ident, ruleSource(&ctx.rule_set, .ts, "local").?);
}

test "context: project without rules dir or rules.yaml keeps global behavior" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try parseGlobal("ratchet: true\n");
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

    var global = try parseGlobal("ratchet: true\n");
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
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/b.ts", .data = "const b = 2;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = s.resolver(null, &global);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/a.ts"))).?;
    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/src/b.ts"))).?;

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings(kata_ident, ruleSource(&first.rule_set, .ts, "local").?);
}

test "cache: distinct projects get their own contexts" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "one/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "two/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/.kata/rules/ts/rule-one.kata", .data = kata_one });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/.kata/rules/ts/rule-two.kata", .data = kata_two });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "one/a.ts", .data = "const a = 1;\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "two/b.ts", .data = "const b = 2;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    rule-one:\n    rule-two:\n");
    defer global.deinit();

    var r = s.resolver(null, &global);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const one = (try cache.acquire(s.arena.allocator(), try s.path("one/a.ts"))).?;
    const two = (try cache.acquire(s.arena.allocator(), try s.path("two/b.ts"))).?;

    try std.testing.expect(one != two);
    try std.testing.expectEqualStrings(kata_one, ruleSource(&one.rule_set, .ts, "rule-one").?);
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&one.rule_set, .ts, "rule-two"));
    try std.testing.expectEqualStrings(kata_two, ruleSource(&two.rule_set, .ts, "rule-two").?);
}

test "cache: unchanged project keeps serving the cached context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = kata_ident });
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
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = kata_local_old });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = s.resolver(null, &global);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(kata_local_old, ruleSource(&first.rule_set, .ts, "local").?);

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = kata_local_new });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(kata_local_new, ruleSource(&second.rule_set, .ts, "local").?);
}

test "cache: added rule file rebuilds the project context" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/one.kata", .data = kata_one });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.ts", .data = "const a = 1;\n" });

    var global = try parseGlobal("rules:\n  ts:\n    one:\n    two:\n");
    defer global.deinit();

    var r = s.resolver(null, &global);
    var cache = context.Cache.init(std.testing.allocator, &r);
    defer cache.deinit();

    const first = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqual(@as(?[]const u8, null), ruleSource(&first.rule_set, .ts, "two"));

    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/two.kata", .data = kata_two });

    const second = (try cache.acquire(s.arena.allocator(), try s.path("proj/a.ts"))).?;
    try std.testing.expectEqualStrings(kata_two, ruleSource(&second.rule_set, .ts, "two").?);
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

test "context: project kata rule lints through the engine" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    no-zzz:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no-zzz", diags[0].rule_id);
    try std.testing.expectEqualStrings("zzz is banned", diags[0].message);
}

test "context: undeclared project kata rule stays inactive" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "context: project composition rule lints through the engine" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const outside_logger_rule =
        \\rule console-outside-logger {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @obj
        \\    }
        \\  }
        \\  where {
        \\    text(@obj) == "console"
        \\    not inside @match class_declaration {
        \\      name: type_identifier @name
        \\      where {
        \\        text(@name) == "Logger"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "console is only allowed inside Logger" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    console-outside-logger:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/console-outside-logger.kata", .data = outside_logger_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "console.log(1);\nclass Logger { log() { console.log(2); } }\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("console-outside-logger", diags[0].rule_id);
    try std.testing.expectEqualStrings("console is only allowed inside Logger", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

test "context: config severity warn demotes rule diagnostics" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    no-zzz:\n      severity: warn\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, diags[0].severity);
}

test "context: config severity error promotes a dsl warn rule" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_warn_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  severity warn
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    no-zzz:\n      severity: error\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_warn_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.@"error", diags[0].severity);
}

test "context: config exclude glob suppresses rule diagnostics for matching paths" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    const yaml =
        "rules:\n" ++
        "  ts:\n" ++
        "    no-zzz:\n" ++
        "      exclude:\n" ++
        "        - 'src/gen/**'\n";
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = yaml });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const excluded = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, "src/gen/a.ts");
    defer gpa.free(excluded);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);

    const kept = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, "src/main.ts");
    defer gpa.free(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
}

test "context: dsl warn severity stays without config severity" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try Setup.init(io);
    defer s.deinit();

    const no_zzz_warn_rule =
        \\rule no-zzz {
        \\  lang ts
        \\  severity warn
        \\  match identifier @match
        \\  where { text(@match) == "zzz" }
        \\  emit @match { message "zzz is banned" }
        \\}
    ;
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    no-zzz:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/no-zzz.kata", .data = no_zzz_warn_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(lint.diagnostic.Severity.warn, diags[0].severity);
}

const isolation_fact_rule =
    \\rule repository-isolation {
    \\  kind project
    \\
    \\  match call @call
    \\
    \\  where {
    \\    endsWith(receiverType(@call), "Repository")
    \\    !endsWith(field(@call, container), "Repository")
    \\  }
    \\
    \\  emit @call {
    \\    message "repositories can only be called by repositories"
    \\  }
    \\}
;

test "context: project fact rule compiles through the resolver" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/project");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  project:\n    repository-isolation:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/project/repository-isolation.kata", .data = isolation_fact_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try ctx.engine.prewarm();
    const fact_rules = ctx.engine.factRules();
    try std.testing.expectEqual(@as(usize, 1), fact_rules.len);
    try std.testing.expectEqualStrings("repository-isolation", fact_rules[0].id);
    try std.testing.expectEqual(lint.fact_rule.FactKind.call, fact_rules[0].fact);
    try std.testing.expectEqual(@as(usize, 2), fact_rules[0].predicates.len);
}

test "context: undeclared project fact rule stays inactive" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/project");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/project/repository-isolation.kata", .data = isolation_fact_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = s.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try ctx.engine.prewarm();
    try std.testing.expectEqual(@as(usize, 0), ctx.engine.factRules().len);
}

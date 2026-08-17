const std = @import("std");

const lint = @import("engine");
const test_fixture = @import("../test_fixture.zig");

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

test "context: no anchor resolves the global context" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/my-user-rule.kata", .data = test_fixture.kata_ident });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    my-user-rule:\n");
    defer global.deinit();

    var r = test_fixture.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(null);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ctx.root);
    try std.testing.expectEqualStrings(test_fixture.kata_ident, test_fixture.ruleSource(&ctx.rule_set, .ts, "my-user-rule").?);
    try std.testing.expectEqual(false, ctx.resolved.ratchet);
}

test "context: anchored file loads project rules on top of user rules" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/shared-rule.kata", .data = kata_shared_user });
    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/shared-rule.kata", .data = kata_shared_project });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/project-only.kata", .data = kata_project_only });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    shared-rule:\n    project-only:\n");
    defer global.deinit();

    var r = test_fixture.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expect(ctx.root != null);
    try std.testing.expect(std.mem.endsWith(u8, ctx.root.?, "proj"));
    try std.testing.expectEqualStrings(kata_shared_project, test_fixture.ruleSource(&ctx.rule_set, .ts, "shared-rule").?);
    try std.testing.expectEqualStrings(kata_project_only, test_fixture.ruleSource(&ctx.rule_set, .ts, "project-only").?);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.warnings.items.len);
}

test "context: project rules.yaml overrides the matching global rule" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/drop-me.kata", .data = test_fixture.kata_ident });
    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "ratchet: true\nrules:\n  ts:\n    drop-me:\n      enabled: false\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    drop-me:\n");
    defer global.deinit();

    var r = test_fixture.resolver(try s.path("user"), &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqual(true, ctx.resolved.ratchet);
    try std.testing.expectEqual(@as(?[]const u8, null), test_fixture.ruleSource(&ctx.rule_set, .ts, "drop-me"));
}

test "context: undeclared rules stay inactive" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/undeclared.kata", .data = test_fixture.kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = test_fixture.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), test_fixture.ruleSource(&ctx.rule_set, .ts, "undeclared"));
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.ts).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.tsx).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.rule_set.get(.go).len);
}

test "context: project rules.yaml enables its own rules" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/ts");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  ts:\n    local:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/ts/local.kata", .data = test_fixture.kata_ident });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = test_fixture.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expectEqualStrings(test_fixture.kata_ident, test_fixture.ruleSource(&ctx.rule_set, .ts, "local").?);
}

test "context: project without rules dir or rules.yaml keeps global behavior" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var global = try test_fixture.parseGlobal("ratchet: true\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try std.testing.expect(ctx.root != null);
    try std.testing.expectEqual(true, ctx.resolved.ratchet);
}

test "context: anchor outside any project falls back to global config" {
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    var global = try test_fixture.parseGlobal("ratchet: true\n");
    defer global.deinit();

    var r = test_fixture.resolver(null, &global);
    const ctx = try r.resolve("/kata-context-test-absent/pkg/main.go");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), ctx.root);
    try std.testing.expectEqual(true, ctx.resolved.ratchet);
}

test "context: malformed project rules.yaml surfaces the parse error" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "nonsense: true\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = test_fixture.resolver(null, null);
    const got = r.resolve(try s.path("proj/src/main.ts"));
    try std.testing.expectError(error.UnknownTopLevelKey, got);
    try std.testing.expectEqual(@as(u32, 1), r.diag.line);
}

test "context: project kata rule lints through the engine" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    const diags = try ctx.engine.lint(gpa, "const zzz = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "context: project composition rule lints through the engine" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
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

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/project");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules.yaml", .data = "rules:\n  project:\n    repository-isolation:\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/project/repository-isolation.kata", .data = isolation_fact_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = test_fixture.resolver(null, null);
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
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/project");
    try s.tmp.dir.createDirPath(io, "proj/src");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/project/repository-isolation.kata", .data = isolation_fact_rule });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/src/main.ts", .data = "const x = 1;\n" });

    var r = test_fixture.resolver(null, null);
    const ctx = try r.resolve(try s.path("proj/src/main.ts"));
    defer ctx.deinit();

    try ctx.engine.prewarm();
    try std.testing.expectEqual(@as(usize, 0), ctx.engine.factRules().len);
}

test "context: rules hash is stable for identical inputs" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/local.kata", .data = test_fixture.kata_local_old });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = test_fixture.resolver(try s.path("user"), &global);

    const first = try r.resolve(null);
    const first_hash = first.rules_hash;
    first.deinit();

    const second = try r.resolve(null);
    defer second.deinit();

    try std.testing.expectEqualSlices(u8, &first_hash, &second.rules_hash);
}

test "context: rules hash changes with rule text" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/local.kata", .data = test_fixture.kata_local_old });

    var global = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer global.deinit();

    var r = test_fixture.resolver(try s.path("user"), &global);
    const before = try r.resolve(null);
    const before_hash = before.rules_hash;
    before.deinit();

    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/local.kata", .data = test_fixture.kata_local_new });

    const after = try r.resolve(null);
    defer after.deinit();

    try std.testing.expect(!std.mem.eql(u8, &before_hash, &after.rules_hash));
}

test "context: rules hash changes with configured severity" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/local.kata", .data = test_fixture.kata_local_old });

    var plain = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer plain.deinit();
    var warned = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n      severity: warn\n");
    defer warned.deinit();

    var r_plain = test_fixture.resolver(try s.path("user"), &plain);
    const plain_ctx = try r_plain.resolve(null);
    const plain_hash = plain_ctx.rules_hash;
    plain_ctx.deinit();

    var r_warned = test_fixture.resolver(try s.path("user"), &warned);
    const warned_ctx = try r_warned.resolve(null);
    defer warned_ctx.deinit();

    try std.testing.expect(!std.mem.eql(u8, &plain_hash, &warned_ctx.rules_hash));
}

test "context: rules hash changes with the match cap" {
    const io = std.testing.io;
    var s = try test_fixture.TmpProject.init();
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "user/ts");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "user/ts/local.kata", .data = test_fixture.kata_local_old });

    var plain = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\n");
    defer plain.deinit();
    var capped = try test_fixture.parseGlobal("rules:\n  ts:\n    local:\nmax-matches-per-file: 3\n");
    defer capped.deinit();

    var r_plain = test_fixture.resolver(try s.path("user"), &plain);
    const plain_ctx = try r_plain.resolve(null);
    const plain_hash = plain_ctx.rules_hash;
    plain_ctx.deinit();

    var r_capped = test_fixture.resolver(try s.path("user"), &capped);
    const capped_ctx = try r_capped.resolve(null);
    defer capped_ctx.deinit();

    try std.testing.expect(!std.mem.eql(u8, &plain_hash, &capped_ctx.rules_hash));
}

const std = @import("std");

const test_rules = @import("test_rules.zig");
const test_fixture = @import("../test_fixture.zig");

const Exit = @import("exit.zig").Exit;
const TestEnv = @import("test_env.zig").TestEnv;

const flag_any_rule =
    \\rule flag-any {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: predefined_type @t
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "as any is not allowed" }
    \\}
;

const no_comments_rule =
    \\rule no-comments {
    \\  lang ts
    \\  match comment @match
    \\  emit @match { message "comments are not allowed" }
    \\}
;

const Setup = struct {
    tmp: std.testing.TmpDir,
    rules_dir: []const u8,
    t: TestEnv,

    fn init(io: std.Io, rule_file: []const u8, rule_body: []const u8, fixture_name: []const u8, fixture_body: []const u8) !Setup {
        var self: Setup = .{
            .tmp = std.testing.tmpDir(.{}),
            .rules_dir = undefined,
            .t = .init(""),
        };
        try self.tmp.dir.createDirPath(io, "rules/ts/tests");
        var path_buf: [128]u8 = undefined;
        const rule_path = try std.fmt.bufPrint(&path_buf, "rules/ts/{s}", .{rule_file});
        try self.tmp.dir.writeFile(io, .{ .sub_path = rule_path, .data = rule_body });
        const fixture_path = try std.fmt.bufPrint(&path_buf, "rules/ts/tests/{s}", .{fixture_name});
        try self.tmp.dir.writeFile(io, .{ .sub_path = fixture_path, .data = fixture_body });

        var rel_buf: [256]u8 = undefined;
        const rel = try test_fixture.relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        self.rules_dir = try std.fmt.allocPrint(self.t.arena.allocator(), "{s}/rules", .{rel});
        return self;
    }

    fn deinit(self: *Setup) void {
        self.t.deinit();
        self.tmp.cleanup();
    }

    fn expectOutput(self: *Setup, comptime fmt: []const u8) !void {
        const fixtures_dir = try std.fmt.allocPrint(self.t.arena.allocator(), "{s}/ts/tests", .{self.rules_dir});
        const expected = try std.mem.replaceOwned(u8, self.t.arena.allocator(), fmt, "{s}", fixtures_dir);

        try std.testing.expectEqualStrings(expected, self.t.out.written());
    }

    fn run(self: *Setup) anyerror!Exit {
        return test_rules.execute(self.t.env(), .{ .rules_dir = self.rules_dir });
    }
};

test "test rules: fixture with satisfied expectations passes" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const x = foo as any;\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: interleaved rules satisfy expectations regardless of order" {
    const io = std.testing.io;
    const aaa_const_rule =
        \\rule aaa-const {
        \\  lang ts
        \\  match lexical_declaration @match
        \\  emit @match { message "declaration" }
        \\}
    ;
    const zzz_call_rule =
        \\rule zzz-call {
        \\  lang ts
        \\  match call_expression @match
        \\  emit @match { message "call" }
        \\}
    ;
    var s = try Setup.init(io, "aaa-const.kata", aaa_const_rule, "sample.ts", "// kata-expect: zzz-call\n" ++
        "foo();\n" ++
        "// kata-expect: aaa-const\n" ++
        "const x = 1;\n" ++
        "// kata-expect: zzz-call\n" ++
        "bar();\n");
    defer s.deinit();
    try s.tmp.dir.writeFile(io, .{ .sub_path = "rules/ts/zzz-call.kata", .data = zzz_call_rule });

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: expected rule that never fires reports missing" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    const expected = try std.fmt.allocPrint(
        s.t.arena.allocator(),
        "{s}/ts/tests/sample.ts:2 missing [flag-any]\ntested 1 fixtures, 1 failures\n",
        .{s.rules_dir},
    );
    try std.testing.expectEqualStrings(expected, s.t.out.written());
}

test "test rules: diagnostic on an unannotated line reports unexpected" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "const x = foo as any;\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    const expected = try std.fmt.allocPrint(
        s.t.arena.allocator(),
        "{s}/ts/tests/sample.ts:1 unexpected [flag-any]\ntested 1 fixtures, 1 failures\n",
        .{s.rules_dir},
    );
    try std.testing.expectEqualStrings(expected, s.t.out.written());
}

test "test rules: missing rules dir is invalid" {
    var t: TestEnv = .init("");
    defer t.deinit();

    const outcome = test_rules.execute(t.env(), .{ .rules_dir = "no-such-dir" });

    try std.testing.expectError(error.InternalReported, outcome);
    try std.testing.expectEqualStrings("kata test: cannot load rules from \"no-such-dir\": RulesDirMissing\n", t.err.written());
}

test "test rules: rule that fails to compile is invalid" {
    const io = std.testing.io;
    var s = try Setup.init(io, "broken.kata",
        \\rule broken {
        \\  lang ts
        \\  match as_expression @match
        \\  where { text(@ghost) == "x" }
        \\  emit @match { message "x" }
        \\}
    , "sample.ts", "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectError(error.InternalReported, outcome);
    try std.testing.expectEqualStrings(
        "kata test: rule ts/broken: unknown capture\n",
        s.t.err.written(),
    );
}

test "test rules: combined language dir runs fixtures for each extension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var t: TestEnv = .init("");
    defer t.deinit();

    try tmp.dir.createDirPath(io, "rules/ts+tsx/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/flag-any.kata", .data = flag_any_rule });
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/tests/sample.ts", .data = "// kata-expect: flag-any\nconst x = foo as any;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/tests/widget.tsx", .data = "// kata-expect: flag-any\nconst y = bar as any;\n" });

    var rel_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&rel_buf, &tmp.sub_path);
    const rules_dir = try std.fmt.allocPrint(t.arena.allocator(), "{s}/rules", .{rel});

    const outcome = test_rules.execute(t.env(), .{ .rules_dir = rules_dir });

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 2 fixtures, 0 failures\n", t.out.written());
}

test "test rules: annotation lines are exempt from diagnostics" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-comments.kata", no_comments_rule, "sample.ts", "// kata-expect: no-comments\n" ++
        "// a forbidden comment\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: duplicate expectations cover duplicate diagnostics on one line" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any, flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: stacked annotations bind to the next code line" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "// kata-expect: flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: annotation on the last line reports dangling" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "const ok: string = \"1\";\n" ++
        "// kata-expect: flag-any\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:2 dangling kata-expect annotation\ntested 1 fixtures, 1 failures\n");
}

test "test rules: annotation without rule ids reports a failure" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect:\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:1 empty kata-expect annotation\ntested 1 fixtures, 1 failures\n");
}

test "test rules: tab-separated annotation ids are recognized" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect:\tflag-any\n" ++
        "const x = foo as any;\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
}

test "test rules: a single expectation does not cover two diagnostics" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:2 unexpected [flag-any]\ntested 1 fixtures, 1 failures\n");
}

test "test rules: kata rule with invalid syntax is invalid" {
    const io = std.testing.io;
    var s = try Setup.init(io, "broken.kata", "rule broken {\n  lang ts\n", "sample.ts", "const ok = 1;\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectError(error.InternalReported, outcome);
    try std.testing.expectEqualStrings(
        "kata test: rule ts/broken: line 3, column 1: invalid rule syntax\n",
        s.t.err.written(),
    );
}

const kata_composition_rule =
    \\rule no-empty-catch {
    \\  lang ts
    \\  match catch_clause @match {
    \\    body: statement_block @body
    \\  }
    \\  where {
    \\    not has @body [throw_statement, call_expression]
    \\  }
    \\  emit @match { message "catch block must handle or rethrow the error" }
    \\}
;

test "test rules: composition rule fixtures run through the same fixture runner" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-empty-catch.kata", kata_composition_rule, "sample.ts", "// kata-expect: no-empty-catch\n" ++
        "try { a(); } catch (e) {}\n" ++
        "try { b(); } catch (e) { rethrow(e); }\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

const parseint_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix safe @fn "Number.parseInt"
    \\  }
    \\}
;

const delete_call_rule =
    \\rule no-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "delete it"
    \\    fix safe ""
    \\  }
    \\}
;

test "test rules: matching kata-expect-fix passes" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", parseint_fix_rule, "sample.ts", "// kata-expect: prefer-number-parseint\n" ++
        "// kata-expect-fix: Number.parseInt\n" ++
        "const n = parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: wrong fix replacement fails printing got and want" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", parseint_fix_rule, "sample.ts", "// kata-expect: prefer-number-parseint\n" ++
        "// kata-expect-fix: Number.parse\n" ++
        "const n = parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:3 wrong fix \"Number.parseInt\" (expected \"Number.parse\")\ntested 1 fixtures, 1 failures\n");
}

test "test rules: kata-expect-fix without a fix reports missing fix" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.kata", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "// kata-expect-fix: unknown\n" ++
        "const x = foo as any;\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:3 missing fix\ntested 1 fixtures, 1 failures\n");
}

test "test rules: empty kata-expect-fix matches a deletion fix" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-parseint.kata", delete_call_rule, "sample.ts", "// kata-expect: no-parseint\n" ++
        "// kata-expect-fix:\n" ++
        "parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("tested 1 fixtures, 0 failures\n", s.t.out.written());
}

test "test rules: dangling kata-expect-fix annotation fails" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", parseint_fix_rule, "sample.ts", "const n = parseInt(y);\n" ++
        "// kata-expect-fix: Number.parseInt\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts:2 dangling kata-expect-fix annotation\n" ++
        "{s}/sample.ts:1 unexpected [prefer-number-parseint]\n" ++
        "warning: rule prefer-number-parseint declares a fix but no fixture asserts it\n" ++
        "tested 1 fixtures, 2 failures\n");
}

const broken_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix safe @fn ")("
    \\  }
    \\}
;

const identity_fix_rule =
    \\rule prefer-number-parseint {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where { text(@fn) == "parseInt" }
    \\  emit @match {
    \\    message "Prefer Number.parseInt"
    \\    fix safe @fn "parseInt"
    \\  }
    \\}
;

test "test rules: a fix that breaks parsing fails naming the rule" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", broken_fix_rule, "sample.ts", "// kata-expect: prefer-number-parseint\n" ++
        "// kata-expect-fix: )(\n" ++
        "const n = parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts fix introduces a syntax error [prefer-number-parseint]\ntested 1 fixtures, 1 failures\n");
}

test "test rules: a fix that never converges fails naming the rule" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", identity_fix_rule, "sample.ts", "// kata-expect: prefer-number-parseint\n" ++
        "// kata-expect-fix: parseInt\n" ++
        "const n = parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.violations, try outcome);
    try s.expectOutput("{s}/sample.ts fixes do not converge [prefer-number-parseint]\ntested 1 fixtures, 1 failures\n");
}

test "test rules: a fix rule without any kata-expect-fix warns without failing" {
    const io = std.testing.io;
    var s = try Setup.init(io, "prefer-number-parseint.kata", parseint_fix_rule, "sample.ts", "// kata-expect: prefer-number-parseint\n" ++
        "const n = parseInt(x);\n");
    defer s.deinit();

    const outcome = s.run();

    try std.testing.expectEqual(Exit.clean, try outcome);
    try std.testing.expectEqualStrings("warning: rule prefer-number-parseint declares a fix but no fixture asserts it\ntested 1 fixtures, 0 failures\n", s.t.out.written());
}

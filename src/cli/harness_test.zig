const std = @import("std");

const harness = @import("harness.zig");
const test_fixture = @import("../test_fixture.zig");

const flag_any_rule =
    \\((as_expression (predefined_type) @t) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any is not allowed"))
    \\
;

const no_comments_rule =
    \\((comment) @match
    \\ (#set! message "comments are not allowed"))
    \\
;

const Setup = struct {
    tmp: std.testing.TmpDir,
    rules_dir: []const u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    arena: std.heap.ArenaAllocator,

    fn init(io: std.Io, rule_file: []const u8, rule_body: []const u8, fixture_name: []const u8, fixture_body: []const u8) !*Setup {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Setup);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .rules_dir = undefined,
            .out = .init(gpa),
            .err = .init(gpa),
            .arena = .init(gpa),
        };
        try self.tmp.dir.createDirPath(io, "rules/ts/tests");
        var path_buf: [128]u8 = undefined;
        const rule_path = try std.fmt.bufPrint(&path_buf, "rules/ts/{s}", .{rule_file});
        try self.tmp.dir.writeFile(io, .{ .sub_path = rule_path, .data = rule_body });
        const fixture_path = try std.fmt.bufPrint(&path_buf, "rules/ts/tests/{s}", .{fixture_name});
        try self.tmp.dir.writeFile(io, .{ .sub_path = fixture_path, .data = fixture_body });

        var rel_buf: [256]u8 = undefined;
        const rel = try test_fixture.relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        self.rules_dir = try std.fmt.allocPrint(self.arena.allocator(), "{s}/rules", .{rel});
        return self;
    }

    fn deinit(self: *Setup) void {
        const gpa = std.testing.allocator;
        self.out.deinit();
        self.err.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

test "harness: fixture with satisfied expectations passes" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const x = foo as any;\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

test "harness: expected rule that never fires reports missing" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.failures, outcome);
    const expected = try std.fmt.allocPrint(
        s.arena.allocator(),
        "{s}/ts/tests/sample.ts:2 missing [flag-any]\ntested 1 fixtures, 1 failures\n",
        .{s.rules_dir},
    );
    try std.testing.expectEqualStrings(expected, s.out.written());
}

test "harness: diagnostic on an unannotated line reports unexpected" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "const x = foo as any;\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.failures, outcome);
    const expected = try std.fmt.allocPrint(
        s.arena.allocator(),
        "{s}/ts/tests/sample.ts:1 unexpected [flag-any]\ntested 1 fixtures, 1 failures\n",
        .{s.rules_dir},
    );
    try std.testing.expectEqualStrings(expected, s.out.written());
}

test "harness: missing rules dir is invalid" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const outcome = try harness.run(io, gpa, arena.allocator(), "no-such-dir", &out.writer, &err.writer);

    try std.testing.expectEqual(harness.Outcome.invalid, outcome);
    try std.testing.expectEqualStrings("kata test: cannot load rules from \"no-such-dir\": RulesDirMissing\n", err.written());
}

test "harness: rule that fails to compile is invalid" {
    const io = std.testing.io;
    var s = try Setup.init(io, "broken.scm", "((as_expression) @match (#unknown-pred? @match))\n", "sample.ts", "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.invalid, outcome);
    try std.testing.expectEqualStrings(
        "kata test: rule ts/broken: unsupported predicate, #set! key, regex, or where expression\n",
        s.err.written(),
    );
}

test "harness: combined language dir runs fixtures for each extension" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    try tmp.dir.createDirPath(io, "rules/ts+tsx/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/flag-any.scm", .data = flag_any_rule });
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/tests/sample.ts", .data = "// kata-expect: flag-any\nconst x = foo as any;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rules/ts+tsx/tests/widget.tsx", .data = "// kata-expect: flag-any\nconst y = bar as any;\n" });

    var rel_buf: [256]u8 = undefined;
    const rel = try test_fixture.relativeTmpPath(&rel_buf, &tmp.sub_path);
    const rules_dir = try std.fmt.allocPrint(arena.allocator(), "{s}/rules", .{rel});

    const outcome = try harness.run(io, gpa, arena.allocator(), rules_dir, &out.writer, &err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tested 2 fixtures, 0 failures") != null);
}

test "harness: annotation lines are exempt from diagnostics" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-comments.scm", no_comments_rule, "sample.ts", "// kata-expect: no-comments\n" ++
        "// a forbidden comment\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

test "harness: duplicate expectations cover duplicate diagnostics on one line" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect: flag-any, flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

test "harness: stacked annotations bind to the next code line" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "// kata-expect: flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

test "harness: annotation on the last line reports dangling" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "const ok: string = \"1\";\n" ++
        "// kata-expect: flag-any\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.failures, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "sample.ts:2 dangling kata-expect annotation") != null);
}

test "harness: annotation without rule ids reports a failure" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect:\n" ++
        "const ok: string = \"1\";\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.failures, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "sample.ts:1 empty kata-expect annotation") != null);
}

test "harness: tab-separated annotation ids are recognized" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect:\tflag-any\n" ++
        "const x = foo as any;\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
}

test "harness: a single expectation does not cover two diagnostics" {
    const io = std.testing.io;
    var s = try Setup.init(io, "flag-any.scm", flag_any_rule, "sample.ts", "// kata-expect: flag-any\n" ++
        "const pair = [foo as any, bar as any];\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.failures, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "sample.ts:2 unexpected [flag-any]") != null);
}

const kata_no_console_rule =
    \\rule no-console {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      object: identifier @receiver
    \\    }
    \\  }
    \\  where { text(@receiver) == "console" }
    \\  emit @match { message "console is not allowed" }
    \\}
;

test "harness: kata rule fixtures run through the same harness" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-console.kata", kata_no_console_rule, "sample.ts", "// kata-expect: no-console\n" ++
        "console.log(1);\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

test "harness: kata rule with invalid syntax is invalid" {
    const io = std.testing.io;
    var s = try Setup.init(io, "broken.kata", "rule broken {\n  lang ts\n", "sample.ts", "const ok = 1;\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.invalid, outcome);
    try std.testing.expectEqualStrings(
        "kata test: rule ts/broken: line 3, column 1: invalid rule syntax\n",
        s.err.written(),
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

test "harness: composition rule fixtures run through the same harness" {
    const io = std.testing.io;
    var s = try Setup.init(io, "no-empty-catch.kata", kata_composition_rule, "sample.ts", "// kata-expect: no-empty-catch\n" ++
        "try { a(); } catch (e) {}\n" ++
        "try { b(); } catch (e) { rethrow(e); }\n");
    defer s.deinit();

    const outcome = try harness.run(io, std.testing.allocator, s.arena.allocator(), s.rules_dir, &s.out.writer, &s.err.writer);

    try std.testing.expectEqual(harness.Outcome.pass, outcome);
    try std.testing.expect(std.mem.indexOf(u8, s.out.written(), "tested 1 fixtures, 0 failures") != null);
}

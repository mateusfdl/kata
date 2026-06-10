const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");
const test_fixture = @import("../test_fixture.zig");

const no_as_any_rule =
    \\((as_expression (predefined_type) @t) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any is not allowed"))
    \\
    \\((as_expression (array_type (predefined_type) @t)) @match
    \\ (#eq? @t "any")
    \\ (#set! message "as any[] is not allowed"))
    \\
;

const blank_identifier_rule =
    \\((short_var_declaration
    \\  left: (expression_list (identifier) @blank)) @match
    \\ (#eq? @blank "_")
    \\ (#set! message "blank identifier discarding function return - errors must be handled explicitly"))
    \\
;

const go_no_console_rule =
    \\((call_expression
    \\  function: (identifier) @name) @match
    \\ (#any-of? @name "print" "println")
    \\ (#set! message "console output is not allowed - use proper instrumentation"))
    \\
    \\((call_expression
    \\  function: (selector_expression
    \\    operand: (identifier) @pkg
    \\    field: (field_identifier) @name)) @match
    \\ (#any-of? @pkg "fmt" "log")
    \\ (#any-of? @name "Print" "Printf" "Println")
    \\ (#set! message "console output is not allowed - use proper instrumentation"))
    \\
;

const no_weak_assertions_rule =
    \\((call_expression
    \\  function: (member_expression
    \\    object: (call_expression
    \\      function: (identifier) @expect)
    \\    property: (property_identifier) @name)) @match
    \\ (#eq? @expect "expect")
    \\ (#any-of? @name "toBeDefined" "toBeUndefined" "toBeNull" "toBeTruthy" "toBeFalsy" "toHaveBeenCalled" "toContain")
    \\ (#set! message "weak assertion - use .toEqual() with explicit values"))
    \\
;

const no_comments_except_directives_rule =
    \\((comment) @match
    \\ (#not-match? @match "^//go:")
    \\ (#set! message "comments are not allowed - code should be self-documenting"))
    \\
;

const todo_comments_rule =
    \\((comment) @match
    \\ (#match? @match "TODO")
    \\ (#set! message "TODO comments are not allowed"))
    \\
;

const Fixture = test_fixture.Fixture;

fn newFixture(allocator: std.mem.Allocator, langs: []const language.Name) !*Fixture {
    return Fixture.init(allocator, langs, "no-as-any", no_as_any_rule);
}

test "engine: detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = (foo[0] as any).bar;";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    const d = diags[0];
    try std.testing.expectEqualStrings("no-as-any", d.rule_id);
    try std.testing.expectEqualStrings("ts", d.language);
    try std.testing.expectEqualStrings("as any is not allowed", d.message);
    try std.testing.expectEqual(@as(u32, 0), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 11), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 0), d.range.end.line);
    try std.testing.expectEqual(@as(u32, 24), d.range.end.column);
}

test "engine: detects `as any[]`" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = foo as any[];";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("as any[] is not allowed", diags[0].message);
}

test "engine: clean sources produce no diagnostics" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const cases = [_][]const u8{
        "const x: string = \"foo\";",
        "const y = foo as string;",
        "const z = foo as unknown as number;",
        "type Handler = (input: string) => number;",
    };

    for (cases) |src| {
        const diags = try f.engine.lint(gpa, src, .ts, null);
        defer gpa.free(diags);
        if (diags.len != 0) {
            std.debug.print("unexpected diagnostics for {s}:\n", .{src});
            for (diags) |d| std.debug.print("  {s}: {s}\n", .{ d.rule_id, d.message });
        }
        try std.testing.expectEqual(@as(usize, 0), diags.len);
    }
}

test "engine: language with zero rules lints clean and stays cached" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f() {\n" ++
        "    _, err := foo()\n" ++
        "}\n";

    const first = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(first);
    try std.testing.expectEqual(@as(usize, 0), first.len);

    const second = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "engine: tsx detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.tsx});
    defer f.deinit();

    const src = "const Comp = () => <div>{(props as any).label}</div>;";
    const diags = try f.engine.lint(gpa, src, .tsx, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("tsx", diags[0].language);
}

test "engine: multiple violations across lines" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const a = x as any;\nconst b = y as any;\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

test "engine: per-language rule filtering" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = foo as any;";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("ts", diags[0].language);

    const tsx_diags = try f.engine.lint(gpa, src, .tsx, null);
    defer gpa.free(tsx_diags);
    try std.testing.expectEqual(@as(usize, 0), tsx_diags.len);
}

test "engine: weak assertions only match expect chains" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{ .ts, .tsx }, "no-weak-assertions", no_weak_assertions_rule);
    defer f.deinit();

    const src =
        "expect(value).toBeDefined();\n" ++
        "console.log(\"foo\");\n" ++
        "value.toBeDefined();\n";

    const ts_diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(ts_diags);
    try std.testing.expectEqual(@as(usize, 1), ts_diags.len);
    try std.testing.expectEqualStrings("no-weak-assertions", ts_diags[0].rule_id);
    try std.testing.expectEqualStrings("weak assertion - use .toEqual() with explicit values", ts_diags[0].message);

    const tsx_diags = try f.engine.lint(gpa, src, .tsx, null);
    defer gpa.free(tsx_diags);
    try std.testing.expectEqual(@as(usize, 1), tsx_diags.len);
    try std.testing.expectEqualStrings("tsx", tsx_diags[0].language);
}

test "engine: go detects blank identifier short declaration" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-swallowed-errors", blank_identifier_rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f() {\n" ++
        "    _, err := foo()\n" ++
        "    _ = err\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no-swallowed-errors", diags[0].rule_id);
    try std.testing.expectEqualStrings("go", diags[0].language);
    try std.testing.expectEqualStrings(
        "blank identifier discarding function return - errors must be handled explicitly",
        diags[0].message,
    );
}

test "engine: not-match? exempts matching comments" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", no_comments_except_directives_rule);
    defer f.deinit();

    const src =
        "//go:build linux\n" ++
        "package main\n" ++
        "// a regular comment\n" ++
        "func f() {}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no-comments", diags[0].rule_id);
    try std.testing.expectEqual(@as(u32, 2), diags[0].range.start.line);
}

test "engine: match? flags only matching comments" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "todo-comments", todo_comments_rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "// TODO refactor this\n" ++
        "// a regular comment\n" ++
        "func f() {}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "engine: exclude-paths suppresses diagnostics for matching paths" {
    const gpa = std.testing.allocator;
    const rule =
        "((comment) @match (#set! exclude-paths \"**/*_test.go vendor/\") (#set! message \"no comments\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();
    const src = "// plain\n";

    const cases = [_]struct { path: ?[]const u8, expected: usize }{
        .{ .path = "pkg/foo_test.go", .expected = 0 },
        .{ .path = "vendor/lib.go", .expected = 0 },
        .{ .path = "pkg/foo.go", .expected = 1 },
        .{ .path = null, .expected = 1 },
    };

    for (cases) |c| {
        const diags = try f.engine.lint(gpa, src, .go, c.path);
        defer gpa.free(diags);
        try std.testing.expectEqual(c.expected, diags.len);
    }
}

test "engine: exclude-paths set directive is accepted" {
    const gpa = std.testing.allocator;
    const rule =
        "((comment) @match (#set! exclude-paths \"*_test.go vendor/\") (#set! message \"no comments\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// plain\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no comments", diags[0].message);
}

test "engine: unknown predicate is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "bad", "((comment) @match (#nope? @match \"x\") (#set! message \"m\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "// hi\n", .go, null));
}

test "engine: unknown set directive key is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "bad", "((comment) @match (#set! mesage \"typo\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "// hi\n", .go, null));
}

test "engine: go detects console output" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-console", go_no_console_rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "import (\n" ++
        "    \"fmt\"\n" ++
        "    \"log\"\n" ++
        ")\n" ++
        "func f() {\n" ++
        "    print(1)\n" ++
        "    fmt.Println(2)\n" ++
        "    log.Printf(\"x\")\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    for (diags) |d| {
        try std.testing.expectEqualStrings("no-console", d.rule_id);
        try std.testing.expectEqualStrings("console output is not allowed - use proper instrumentation", d.message);
    }
}

const repo_complexity_rule =
    \\((class_declaration
    \\   name: (type_identifier) @name
    \\   body: (class_body (method_definition) @fn)) @match
    \\ (#match? @name "Repository$")
    \\ (#where? "(> (complexity @fn) 2)")
    \\ (#set! message "repository methods must keep complexity <= 2"))
    \\
;

test "engine: where scopes complexity to matching classes only" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "repo-complexity", repo_complexity_rule);
    defer f.deinit();

    const src =
        "class UserRepository {\n" ++
        "  find(a, b) {\n" ++
        "    if (a) {\n" ++
        "      if (b) { return 1; }\n" ++
        "    }\n" ++
        "    return 2;\n" ++
        "  }\n" ++
        "}\n" ++
        "class OrderService {\n" ++
        "  create(a, b) {\n" ++
        "    if (a) {\n" ++
        "      if (b) { return 1; }\n" ++
        "    }\n" ++
        "    return 2;\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("repo-complexity", diags[0].rule_id);
    try std.testing.expectEqualStrings("repository methods must keep complexity <= 2", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

test "engine: where complexity excludes nested functions" {
    const gpa = std.testing.allocator;
    const rule =
        \\((method_definition) @match
        \\ (#where? "(> (complexity @match) 1)")
        \\ (#set! message "too complex"))
        \\
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "method-complexity", rule);
    defer f.deinit();

    const src =
        "class UserRepository {\n" ++
        "  find(xs) {\n" ++
        "    const f = (x) => {\n" ++
        "      if (x) return 1;\n" ++
        "      return 2;\n" ++
        "    };\n" ++
        "    return xs.map(f);\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where scopes complexity to go receiver types" {
    const gpa = std.testing.allocator;
    const rule =
        \\((method_declaration
        \\   receiver: (parameter_list (parameter_declaration type: (pointer_type (type_identifier) @recv)))) @match
        \\ (#match? @recv "Repository$")
        \\ (#where? "(> (complexity @match) 1)")
        \\ (#set! message "repository methods must keep complexity <= 1"))
        \\
    ;
    var f = try Fixture.init(gpa, &.{.go}, "repo-complexity", rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func (r *UserRepository) Find(a int) int {\n" ++
        "\tif a > 0 {\n" ++
        "\t\treturn 1\n" ++
        "\t}\n" ++
        "\treturn 2\n" ++
        "}\n" ++
        "func (s *OrderService) Create(a int) int {\n" ++
        "\tif a > 0 {\n" ++
        "\t\treturn 1\n" ++
        "\t}\n" ++
        "\treturn 2\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "engine: where nesting fires beyond the threshold" {
    const gpa = std.testing.allocator;
    const rule =
        \\((function_declaration) @match
        \\ (#where? "(> (nesting @match) 2)")
        \\ (#set! message "too deep"))
        \\
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "max-nesting", rule);
    defer f.deinit();

    const deep =
        "function deep(a) {\n" ++
        "  if (a) {\n" ++
        "    for (;;) {\n" ++
        "      if (a) b();\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, deep, .ts, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("too deep", diags[0].message);

    const shallow =
        "function shallow(a) {\n" ++
        "  if (a) {\n" ++
        "    for (;;) {\n" ++
        "      b();\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";
    const clean = try f.engine.lint(gpa, shallow, .ts, null);
    defer gpa.free(clean);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "engine: where composes length and complexity" {
    const gpa = std.testing.allocator;
    const rule =
        \\((method_definition) @match
        \\ (#where? "(and (> (length @match) 3) (> (complexity @match) 1))")
        \\ (#set! message "long and complex"))
        \\
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "long-complex", rule);
    defer f.deinit();

    const src =
        "class C {\n" ++
        "  longComplex(a) {\n" ++
        "    if (a) { b(); }\n" ++
        "    c();\n" ++
        "    d();\n" ++
        "  }\n" ++
        "  longSimple() {\n" ++
        "    a();\n" ++
        "    b();\n" ++
        "    c();\n" ++
        "  }\n" ++
        "  shortComplex(a) { return a ? 1 : 2; }\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("long and complex", diags[0].message);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "engine: malformed where expression is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((method_definition) @match (#where? \"(> (complexity @match) lots)\") (#set! message \"m\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "class C { m() {} }", .ts, null));
}

test "engine: where expression referencing unknown capture is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((method_definition) @match (#where? \"(> (complexity @nope) 1)\") (#set! message \"m\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "class C { m() {} }", .ts, null));
}

test "engine: where without exactly one string argument is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((method_definition) @match (#where? @match \"(> 1 0)\") (#set! message \"m\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "class C { m() {} }", .ts, null));
}

test "engine: severity defaults to error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
}

test "engine: set severity warn stamps warn on diagnostics" {
    const gpa = std.testing.allocator;
    const rule =
        "((comment) @match (#set! severity \"warn\") (#set! message \"no comments\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// hi\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.warn, diags[0].severity);
    try std.testing.expectEqualStrings("no comments", diags[0].message);
}

test "engine: set severity error keeps error" {
    const gpa = std.testing.allocator;
    const rule =
        "((comment) @match (#set! severity \"error\") (#set! message \"no comments\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// hi\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
}

test "engine: unknown severity value is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "bad", "((comment) @match (#set! severity \"info\") (#set! message \"m\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.RuleCompileFailed, f.engine.lint(gpa, "// hi\n", .go, null));
}

test "engine: warnings list demotes matching rule to warn" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();
    f.engine.warnings = &.{.{ .lang = null, .id = "no-as-any" }};

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.warn, diags[0].severity);
}

test "engine: warnings list scoped to another language keeps error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();
    f.engine.warnings = &.{.{ .lang = .go, .id = "no-as-any" }};

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
}

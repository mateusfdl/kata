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

test "engine: where params counts ts function parameters" {
    const gpa = std.testing.allocator;
    const rule =
        "((function_declaration) @match (#where? \"(> (params @match) 4)\") (#set! message \"too many params\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "max-params", rule);
    defer f.deinit();

    const src =
        "function wide(a, b, c, d, e) {}\n" ++
        "function narrow(a, b, c, d) {}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqualStrings("too many params", diags[0].message);
}

test "engine: where params counts go grouped parameter names" {
    const gpa = std.testing.allocator;
    const rule =
        "((function_declaration) @match (#where? \"(> (params @match) 4)\") (#set! message \"too many params\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "max-params", rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func wide(a, b, c int, d string, e ...bool) {}\n" ++
        "func narrow(a, b int, c string) {}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "engine: where args counts call arguments" {
    const gpa = std.testing.allocator;
    const rule =
        "((call_expression) @match (#where? \"(> (args @match) 3)\") (#set! message \"too many args\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "max-args", rule);
    defer f.deinit();

    const src = "f(1, 2, 3, 4);\ng(1, 2, 3);\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

test "engine: where args ignores comments between arguments" {
    const gpa = std.testing.allocator;
    const rule =
        "((call_expression) @match (#where? \"(> (args @match) 2)\") (#set! message \"too many args\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "max-args", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "f(1, /* note */ 2);\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where params ignores comments in ts parameter list" {
    const gpa = std.testing.allocator;
    const rule =
        "((function_declaration) @match (#where? \"(> (params @match) 2)\") (#set! message \"too many params\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "max-params", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "function f(a, /* note */ b) {}\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where params ignores comments in go parameter list" {
    const gpa = std.testing.allocator;
    const rule =
        "((function_declaration) @match (#where? \"(> (params @match) 2)\") (#set! message \"too many params\"))\n";
    var f = try Fixture.init(gpa, &.{.go}, "max-params", rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f(a, b int /* note */) {}\n";
    const diags = try f.engine.lint(gpa, src, .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where text compares numeric capture text" {
    const gpa = std.testing.allocator;
    const rule =
        "((variable_declarator value: (number) @n) @match (#where? \"(> (text @n) 30000)\") (#set! message \"timeout too long\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "short-timeouts", rule);
    defer f.deinit();

    const src = "const slow = 60000;\nconst fast = 100;\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqualStrings("timeout too long", diags[0].message);
}

test "engine: where text on non-numeric capture never fires" {
    const gpa = std.testing.allocator;
    const rule =
        "((variable_declarator name: (identifier) @n) @match (#where? \"(>= (text @n) 0)\") (#set! message \"m\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "never", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "const name = \"x\";\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: message interpolates measures and capture text" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        "((function_declaration name: (identifier) @name) @match" ++
        " (#where? \"(> (complexity @match) 2)\")" ++
        " (#set! message \"complexity {complexity @match} exceeds 2 in {text @name}\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "max-complexity", rule);
    defer f.deinit();

    const src =
        "function handler(a, b) {\n" ++
        "  if (a) { return 1; }\n" ++
        "  if (b) { return 2; }\n" ++
        "  return 3;\n" ++
        "}\n";
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("complexity 3 exceeds 2 in handler", diags[0].message);
}

test "engine: message interpolation works without a where predicate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        "((function_declaration) @match (#set! message \"spans {length @match} lines\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "length-report", rule);
    defer f.deinit();

    const src =
        "function f() {\n" ++
        "  return 1;\n" ++
        "}\n";
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("spans 3 lines", diags[0].message);
}

test "engine: message renders doubled braces as literals" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        "((function_declaration) @match (#set! message \"avoid interface{{}} here\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "no-empty-iface", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "function f() {}", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("avoid interface{} here", diags[0].message);
}

test "engine: message renders escaped braces around a placeholder" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        "((function_declaration) @match (#set! message \"{{{length @match}}}\"))\n";
    var f = try Fixture.init(gpa, &.{.ts}, "length-report", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "function f() {}", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("{1}", diags[0].message);
}

test "engine: message with unknown placeholder measure is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((function_declaration) @match (#set! message \"{lines @match}\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.UnknownPlaceholderMeasure, f.engine.lint(gpa, "function f() {}", .ts, null));
    try std.testing.expectEqualStrings("unknown measure in message placeholder", f.engine.compile_diag.detail);
}

test "engine: message with unknown placeholder capture is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((function_declaration) @match (#set! message \"{length @nope}\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.UnknownPlaceholderCapture, f.engine.lint(gpa, "function f() {}", .ts, null));
    try std.testing.expectEqualStrings("unknown capture in message placeholder", f.engine.compile_diag.detail);
}

test "engine: message with unclosed placeholder is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((function_declaration) @match (#set! message \"oops {length @match\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.UnclosedPlaceholder, f.engine.lint(gpa, "function f() {}", .ts, null));
    try std.testing.expectEqualStrings("unclosed { in message, use {{ for a literal", f.engine.compile_diag.detail);
}

test "engine: message with stray close brace is a hard error" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "bad", "((function_declaration) @match (#set! message \"oops } here\"))\n");
    defer f.deinit();

    try std.testing.expectError(error.StrayBraceInMessage, f.engine.lint(gpa, "function f() {}", .ts, null));
    try std.testing.expectEqualStrings("stray } in message, use }} for a literal", f.engine.compile_diag.detail);
}

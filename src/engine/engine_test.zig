const std = @import("std");
const diagnostic = @import("engine").diagnostic;
const family = @import("engine").family;
const language = @import("engine").language;
const test_fixture = @import("../test_fixture.zig");

test "engine: family adapters classify enclosing context kinds" {
    const Case = struct {
        family: family.Family,
        kind_name: []const u8,
        context_kind: diagnostic.ContextKind,
    };
    const cases = [_]Case{
        .{ .family = .ts_family, .kind_name = "function_declaration", .context_kind = .function },
        .{ .family = .ts_family, .kind_name = "function_expression", .context_kind = .function },
        .{ .family = .ts_family, .kind_name = "generator_function_declaration", .context_kind = .function },
        .{ .family = .ts_family, .kind_name = "generator_function", .context_kind = .function },
        .{ .family = .ts_family, .kind_name = "arrow_function", .context_kind = .function },
        .{ .family = .ts_family, .kind_name = "method_definition", .context_kind = .method },
        .{ .family = .ts_family, .kind_name = "class_declaration", .context_kind = .class },
        .{ .family = .ts_family, .kind_name = "abstract_class_declaration", .context_kind = .class },
        .{ .family = .ts_family, .kind_name = "interface_declaration", .context_kind = .class },
        .{ .family = .ts_family, .kind_name = "internal_module", .context_kind = .namespace },
        .{ .family = .ts_family, .kind_name = "module", .context_kind = .namespace },
        .{ .family = .go, .kind_name = "function_declaration", .context_kind = .function },
        .{ .family = .go, .kind_name = "method_declaration", .context_kind = .method },
        .{ .family = .go, .kind_name = "type_declaration", .context_kind = .class },
    };

    for (cases) |case| {
        const adapter = family.of(case.family);
        const kind_id = adapter.kindId(case.kind_name, true);

        try std.testing.expectEqual(case.context_kind, adapter.contextKind(kind_id).?);
    }

    for ([_]family.Family{ .ts_family, .go }) |family_name| {
        const adapter = family.of(family_name);
        const kind_id = adapter.kindId("if_statement", true);

        try std.testing.expectEqual(@as(?diagnostic.ContextKind, null), adapter.contextKind(kind_id));
    }
}

test "engine: family adapters expose the dense kind count" {
    const node_kinds = @import("node_kinds");

    try std.testing.expectEqual(node_kinds.ts_family.kind_count, family.of(.ts_family).kind_count);
    try std.testing.expectEqual(node_kinds.go.kind_count, family.of(.go).kind_count);
    try std.testing.expectEqual(
        family.of(.ts_family).kindId("call_expression", true) < family.of(.ts_family).kind_count,
        true,
    );
    try std.testing.expectEqual(
        family.of(.go).kindId("call_expression", true) < family.of(.go).kind_count,
        true,
    );
}

const kata_no_as_any_rule =
    \\rule no-as-any {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: predefined_type @t
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "as any is not allowed" }
    \\}
    \\rule no-as-any {
    \\  lang ts, tsx
    \\  match as_expression @match {
    \\    child: array_type {
    \\      child: predefined_type @t
    \\    }
    \\  }
    \\  where { text(@t) == "any" }
    \\  emit @match { message "as any[] is not allowed" }
    \\}
;

const blank_identifier_rule =
    \\rule no-swallowed-errors {
    \\  lang go
    \\  match short_var_declaration @match {
    \\    left: expression_list {
    \\      child: identifier @blank
    \\    }
    \\  }
    \\  where { text(@blank) == "_" }
    \\  emit @match { message "blank identifier discarding function return - errors must be handled explicitly" }
    \\}
;

const go_no_console_rule =
    \\rule no-console {
    \\  lang go
    \\  match call_expression @match {
    \\    function: identifier @name
    \\  }
    \\  where { anyOf(text(@name), "print", "println") }
    \\  emit @match { message "console output is not allowed - use proper instrumentation" }
    \\}
    \\rule no-console {
    \\  lang go
    \\  match call_expression @match {
    \\    function: selector_expression {
    \\      operand: identifier @pkg
    \\      field: field_identifier @name
    \\    }
    \\  }
    \\  where {
    \\    anyOf(text(@pkg), "fmt", "log")
    \\    anyOf(text(@name), "Print", "Printf", "Println")
    \\  }
    \\  emit @match { message "console output is not allowed - use proper instrumentation" }
    \\}
;

const no_weak_assertions_rule =
    \\rule no-weak-assertions {
    \\  lang ts, tsx
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      object: call_expression {
    \\        function: identifier @expect
    \\      }
    \\      property: property_identifier @name
    \\    }
    \\  }
    \\  where {
    \\    text(@expect) == "expect"
    \\    anyOf(text(@name), "toBeDefined", "toBeUndefined", "toBeNull", "toBeTruthy", "toBeFalsy", "toHaveBeenCalled", "toContain")
    \\  }
    \\  emit @match { message "weak assertion - use .toEqual() with explicit values" }
    \\}
;

const no_comments_except_directives_rule =
    \\rule no-comments {
    \\  lang go
    \\  match comment @match
    \\  where { !matches(text(@match), "^//go:") }
    \\  emit @match { message "comments are not allowed - code should be self-documenting" }
    \\}
;

const todo_comments_rule =
    \\rule todo-comments {
    \\  lang go
    \\  match comment @match
    \\  where { matches(text(@match), "TODO") }
    \\  emit @match { message "TODO comments are not allowed" }
    \\}
;

const cross_grammar_print_rule =
    \\rule no-print-call {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @name
    \\  }
    \\  where { text(@name) == "print" }
    \\  emit @match { message "print calls are not allowed" }
    \\}
;

const Fixture = test_fixture.Fixture;

fn newFixture(allocator: std.mem.Allocator, langs: []const language.Name) !*Fixture {
    return Fixture.init(allocator, langs, "no-as-any", kata_no_as_any_rule);
}

fn expectContextEntry(entry: diagnostic.Context, kind: diagnostic.ContextKind, name: []const u8) !void {
    try std.testing.expectEqual(kind, entry.kind);
    try std.testing.expectEqualStrings(name, entry.name);
}

test "engine: diagnostics carry class and method context" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const source =
        "class Editor {\n" ++
        "  render() {\n" ++
        "    return value as any;\n" ++
        "  }\n" ++
        "}\n";
    const diagnostics = try f.engine.lint(arena.allocator(), source, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), diagnostics[0].context.len);
    try expectContextEntry(diagnostics[0].context[0], .class, "Editor");
    try std.testing.expectEqual(diagnostic.Range{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 4, .column = 1 },
    }, diagnostics[0].context[0].range);
    try expectContextEntry(diagnostics[0].context[1], .method, "render");
    try std.testing.expectEqual(diagnostic.Range{
        .start = .{ .line = 1, .column = 2 },
        .end = .{ .line = 3, .column = 3 },
    }, diagnostics[0].context[1].range);
}

test "engine: diagnostics name arrow contexts from declarators" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const source = "const handler = () => value as any;\n";
    const diagnostics = try f.engine.lint(arena.allocator(), source, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), diagnostics[0].context.len);
    try expectContextEntry(diagnostics[0].context[0], .function, "handler");
}

test "engine: diagnostics name anonymous function contexts" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const source = "(() => value as any)();\n";
    const diagnostics = try f.engine.lint(arena.allocator(), source, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), diagnostics[0].context.len);
    try expectContextEntry(diagnostics[0].context[0], .function, "<anonymous>");
}

test "engine: diagnostics keep the innermost four contexts" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const source =
        "const a = () => {\n" ++
        "  const b = () => {\n" ++
        "    const c = () => {\n" ++
        "      const d = () => {\n" ++
        "        const e = () => value as any;\n" ++
        "      };\n" ++
        "    };\n" ++
        "  };\n" ++
        "};\n";
    const diagnostics = try f.engine.lint(arena.allocator(), source, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 4), diagnostics[0].context.len);
    try expectContextEntry(diagnostics[0].context[0], .function, "b");
    try expectContextEntry(diagnostics[0].context[1], .function, "c");
    try expectContextEntry(diagnostics[0].context[2], .function, "d");
    try expectContextEntry(diagnostics[0].context[3], .function, "e");
}

test "engine: a matched function is not its own context" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        \\rule function-finding {
        \\  lang ts
        \\  match function_declaration @match
        \\  emit @match { message "function finding" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "function-finding", rule);
    defer f.deinit();

    const diagnostics = try f.engine.lint(arena.allocator(), "function top() {}\n", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), diagnostics[0].context.len);
}

test "engine: go diagnostics carry type and method contexts" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const field_rule =
        \\rule field-finding {
        \\  lang go
        \\  match field_identifier @match
        \\  emit @match { message "field finding" }
        \\}
    ;
    var type_fixture = try Fixture.init(gpa, &.{.go}, "field-finding", field_rule);
    defer type_fixture.deinit();

    const type_diagnostics = try type_fixture.engine.lint(arena.allocator(), "package main\ntype T struct { value int }\n", .go, null);
    try std.testing.expectEqual(@as(usize, 1), type_diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), type_diagnostics[0].context.len);
    try expectContextEntry(type_diagnostics[0].context[0], .class, "T");

    var method_fixture = try Fixture.init(gpa, &.{.go}, "no-swallowed-errors", blank_identifier_rule);
    defer method_fixture.deinit();
    const method_source =
        "package main\n" ++
        "type T struct{}\n" ++
        "func (t T) m() {\n" ++
        "  _, err := call()\n" ++
        "}\n";
    const method_diagnostics = try method_fixture.engine.lint(arena.allocator(), method_source, .go, null);
    try std.testing.expectEqual(@as(usize, 1), method_diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), method_diagnostics[0].context.len);
    try expectContextEntry(method_diagnostics[0].context[0], .class, "T");
    try expectContextEntry(method_diagnostics[0].context[1], .method, "m");
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try newFixture(gpa, &.{.tsx});
    defer f.deinit();

    const src = "const Comp = () => <div>{(props as any).label}</div>;";
    const diags = try f.engine.lint(arena.allocator(), src, .tsx, null);

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

test "engine: ts rules never evaluate go sources" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-print-call", cross_grammar_print_rule);
    defer f.deinit();

    const ts_diags = try f.engine.lint(gpa, "print(\"x\");", .ts, null);
    defer gpa.free(ts_diags);
    try std.testing.expectEqual(@as(usize, 1), ts_diags.len);
    try std.testing.expectEqualStrings("ts", ts_diags[0].language);

    const go_src = "package main\n\nfunc run() {\n\tprint(\"x\")\n}\n";
    const go_diags = try f.engine.lint(gpa, go_src, .go, null);
    defer gpa.free(go_diags);
    try std.testing.expectEqual(@as(usize, 0), go_diags.len);
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.init(gpa, &.{.go}, "no-swallowed-errors", blank_identifier_rule);
    defer f.deinit();

    const src =
        "package main\n" ++
        "func f() {\n" ++
        "    _, err := foo()\n" ++
        "    _ = err\n" ++
        "}\n";
    const diags = try f.engine.lint(arena.allocator(), src, .go, null);

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
        \\rule no-comments {
        \\  lang go
        \\  exclude paths "**/*_test.go", "vendor/"
        \\  match comment @match
        \\  emit @match { message "no comments" }
        \\}
    ;
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
        \\rule no-comments {
        \\  lang go
        \\  exclude paths "*_test.go", "vendor/"
        \\  match comment @match
        \\  emit @match { message "no comments" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// plain\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no comments", diags[0].message);
}

test "engine: go detects console output" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
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
    const diags = try f.engine.lint(arena.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    for (diags) |d| {
        try std.testing.expectEqualStrings("no-console", d.rule_id);
        try std.testing.expectEqualStrings("console output is not allowed - use proper instrumentation", d.message);
    }
}

const repo_complexity_rule =
    \\rule repo-complexity {
    \\  lang ts
    \\  match class_declaration @match {
    \\    name: type_identifier @name
    \\    body: class_body {
    \\      child: method_definition @fn
    \\    }
    \\  }
    \\  where {
    \\    matches(text(@name), "Repository$")
    \\    complexity(@fn) > 2
    \\  }
    \\  emit @match { message "repository methods must keep complexity <= 2" }
    \\}
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
        \\rule method-complexity {
        \\  lang ts
        \\  match method_definition @match
        \\  where { complexity(@match) > 1 }
        \\  emit @match { message "too complex" }
        \\}
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
        \\rule repo-complexity {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: parameter_list {
        \\      child: parameter_declaration {
        \\        type: pointer_type {
        \\          child: type_identifier @recv
        \\        }
        \\      }
        \\    }
        \\  }
        \\  where {
        \\    matches(text(@recv), "Repository$")
        \\    complexity(@match) > 1
        \\  }
        \\  emit @match { message "repository methods must keep complexity <= 1" }
        \\}
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
        \\rule max-nesting {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { nesting(@match) > 2 }
        \\  emit @match { message "too deep" }
        \\}
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        \\rule long-complex {
        \\  lang ts
        \\  match method_definition @match
        \\  where {
        \\    length(@match) > 3
        \\    complexity(@match) > 1
        \\  }
        \\  emit @match { message "long and complex" }
        \\}
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
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("long and complex", diags[0].message);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "engine: severity defaults to error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
    try std.testing.expectEqual(diagnostic.Maturity.stable, diags[0].maturity);
}

test "engine: maturity deprecated stamps diagnostics" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule no-comments {
        \\  lang go
        \\  maturity deprecated
        \\  match comment @match
        \\  emit @match { message "no comments" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// hi\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Maturity.deprecated, diags[0].maturity);
}

test "engine: set severity warn stamps warn on diagnostics" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule no-comments {
        \\  lang go
        \\  severity warn
        \\  match comment @match
        \\  emit @match { message "no comments" }
        \\}
    ;
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
        \\rule no-comments {
        \\  lang go
        \\  severity error
        \\  match comment @match
        \\  emit @match { message "no comments" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "// hi\n", .go, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
}

test "engine: setting severity warn demotes matching rule" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();
    f.engine.settings = &.{.{ .lang = .ts, .id = "no-as-any", .severity = .warn }};

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.warn, diags[0].severity);
}

test "engine: setting exclude glob suppresses diagnostics for matching paths" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();
    f.engine.settings = &.{.{ .lang = .ts, .id = "no-as-any", .exclude = &.{"src/gen/**"} }};

    const excluded = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, "src/gen/a.ts");
    defer gpa.free(excluded);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);

    const kept = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, "src/main.ts");
    defer gpa.free(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
}

test "engine: setting scoped to another language keeps error" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();
    f.engine.settings = &.{.{ .lang = .go, .id = "no-as-any", .severity = .warn }};

    const diags = try f.engine.lint(gpa, "const x = (foo[0] as any).bar;", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diags[0].severity);
}

test "engine: where params counts ts function parameters" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule max-params {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { params(@match) > 4 }
        \\  emit @match { message "too many params" }
        \\}
    ;
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
        \\rule max-params {
        \\  lang go
        \\  match function_declaration @match
        \\  where { params(@match) > 4 }
        \\  emit @match { message "too many params" }
        \\}
    ;
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
        \\rule max-args {
        \\  lang ts
        \\  match call_expression @match
        \\  where { args(@match) > 3 }
        \\  emit @match { message "too many args" }
        \\}
    ;
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
        \\rule max-args {
        \\  lang ts
        \\  match call_expression @match
        \\  where { args(@match) > 2 }
        \\  emit @match { message "too many args" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "max-args", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "f(1, /* note */ 2);\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where params ignores comments in ts parameter list" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule max-params {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { params(@match) > 2 }
        \\  emit @match { message "too many params" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "max-params", rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "function f(a, /* note */ b) {}\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine: where params ignores comments in go parameter list" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule max-params {
        \\  lang go
        \\  match function_declaration @match
        \\  where { params(@match) > 2 }
        \\  emit @match { message "too many params" }
        \\}
    ;
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
        \\rule short-timeouts {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    value: number @n
        \\  }
        \\  where { text(@n) > 30000 }
        \\  emit @match { message "timeout too long" }
        \\}
    ;
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
        \\rule never {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    name: identifier @n
        \\  }
        \\  where { text(@n) >= 0 }
        \\  emit @match { message "m" }
        \\}
    ;
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
        \\rule max-complexity {
        \\  lang ts
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\  }
        \\  where { complexity(@match) > 2 }
        \\  emit @match { message "complexity {complexity(@match)} exceeds 2 in {text(@name)}" }
        \\}
    ;
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
        \\rule length-report {
        \\  lang ts
        \\  match function_declaration @match
        \\  emit @match { message "spans {length(@match)} lines" }
        \\}
    ;
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
        \\rule no-empty-iface {
        \\  lang ts
        \\  match function_declaration @match
        \\  emit @match { message "avoid interface{{}} here" }
        \\}
    ;
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
        \\rule length-report {
        \\  lang ts
        \\  match function_declaration @match
        \\  emit @match { message "{{{length(@match)}}}" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "length-report", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "function f() {}", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("{1}", diags[0].message);
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

test "engine: lints with a kata rule" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-console", kata_no_console_rule);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "console.log(1);\nfoo.bar(2);\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no-console", diags[0].rule_id);
    try std.testing.expectEqualStrings("ts", diags[0].language);
    try std.testing.expectEqualStrings("console is not allowed", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 14), diags[0].range.end.column);
}

test "engine: multiple kata rules fire together" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-as-any", kata_no_as_any_rule);
    defer f.deinit();
    try f.add(.ts, "no-console", kata_no_console_rule);

    const diags = try f.engine.lint(gpa, "const x = (y as any).z;\nconsole.log(1);\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("no-as-any", diags[0].rule_id);
    try std.testing.expectEqualStrings("no-console", diags[1].rule_id);
}

const kata_aaa_const_rule =
    \\rule aaa-const {
    \\  lang ts
    \\  match lexical_declaration @match
    \\  emit @match { message "declaration" }
    \\}
;

const kata_zzz_call_rule =
    \\rule zzz-call {
    \\  lang ts
    \\  match call_expression @match
    \\  emit @match { message "call" }
    \\}
;

const kata_aaa_call_rule =
    \\rule aaa-call {
    \\  lang ts
    \\  match call_expression @match
    \\  emit @match { message "call" }
    \\}
;

test "engine: diagnostics come out in source position order across rules" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "aaa-const", kata_aaa_const_rule);
    defer f.deinit();
    try f.add(.ts, "zzz-call", kata_zzz_call_rule);

    const diags = try f.engine.lint(gpa, "foo();\nconst x = 1;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("zzz-call", diags[0].rule_id);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqualStrings("aaa-const", diags[1].rule_id);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

test "engine: rules on the same node emit in rule id order" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "zzz-call", kata_zzz_call_rule);
    defer f.deinit();
    try f.add(.ts, "aaa-call", kata_aaa_call_rule);

    const diags = try f.engine.lint(gpa, "foo();\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("aaa-call", diags[0].rule_id);
    try std.testing.expectEqualStrings("zzz-call", diags[1].rule_id);
}

test "engine: kata measure rules use the metric context" {
    const gpa = std.testing.allocator;
    const measured =
        \\rule max-complexity {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { complexity(@match) > 1 }
        \\  emit @match { message "complexity {complexity(@match)} exceeds 1" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "max-complexity", measured);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const src = "function f(a: number) { if (a) { return 1; } if (!a) { return 2; } return 3; }\n";
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("complexity 3 exceeds 1", diags[0].message);
}

test "engine: kata parse error reports the rule id and position" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-x", "rule no-x {\n  lang ts\n");
    defer f.deinit();

    try std.testing.expectError(error.CompileFailed, f.engine.lint(gpa, "x;\n", .ts, null));
    try std.testing.expectEqual(language.Name.ts, f.engine.compile_diag.lang.?);
    try std.testing.expectEqualStrings("no-x", f.engine.compile_diag.rule_id);
    try std.testing.expectEqualStrings("invalid rule syntax", f.engine.compile_diag.detail);
    try std.testing.expectEqual(@as(u32, 3), f.engine.compile_diag.line);
    try std.testing.expectEqual(@as(u32, 1), f.engine.compile_diag.column);
}

test "engine: kata rule id must match the file name" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "other-name", kata_no_console_rule);
    defer f.deinit();

    try std.testing.expectError(error.CompileFailed, f.engine.lint(gpa, "x;\n", .ts, null));
    try std.testing.expectEqualStrings("other-name", f.engine.compile_diag.rule_id);
    try std.testing.expectEqualStrings("rule id does not match the file name", f.engine.compile_diag.detail);
}

test "engine: kata rule must declare the directory language" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-console", kata_no_console_rule);
    defer f.deinit();

    try std.testing.expectError(error.CompileFailed, f.engine.lint(gpa, "package main\n", .go, null));
    try std.testing.expectEqual(language.Name.go, f.engine.compile_diag.lang.?);
    try std.testing.expectEqualStrings("rule does not declare this language", f.engine.compile_diag.detail);
}

test "engine: kata rule variants in one file all fire" {
    const gpa = std.testing.allocator;
    const variants =
        \\rule no-any {
        \\  lang ts
        \\  match type_annotation @match {
        \\    child: predefined_type @t
        \\  }
        \\  where { text(@t) == "any" }
        \\  emit @match { message "any is not allowed" }
        \\}
        \\rule no-any {
        \\  lang ts
        \\  match as_expression @match {
        \\    child: predefined_type @t
        \\  }
        \\  where { text(@t) == "any" }
        \\  emit @match { message "as any is not allowed" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "no-any", variants);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "const x: any = y as any;\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("no-any", diags[0].rule_id);
    try std.testing.expectEqualStrings("any is not allowed", diags[0].message);
    try std.testing.expectEqualStrings("no-any", diags[1].rule_id);
    try std.testing.expectEqualStrings("as any is not allowed", diags[1].message);
}

test "engine: kata variant with a different id fails" {
    const gpa = std.testing.allocator;
    const two_rules =
        \\rule no-a {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match { message "a" }
        \\}
        \\rule no-b {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match { message "b" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "no-a", two_rules);
    defer f.deinit();

    try std.testing.expectError(error.CompileFailed, f.engine.lint(gpa, "x;\n", .ts, null));
    try std.testing.expectEqualStrings("rule id does not match the file name", f.engine.compile_diag.detail);
}

test "engine: project kata rules cannot load from language dirs" {
    const gpa = std.testing.allocator;
    const project_rule =
        \\rule boundaries {
        \\  kind project
        \\  emit @match { message "m" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "boundaries", project_rule);
    defer f.deinit();

    try std.testing.expectError(error.CompileFailed, f.engine.lint(gpa, "x;\n", .ts, null));
    try std.testing.expectEqualStrings("project rules are not supported yet", f.engine.compile_diag.detail);
}

const kata_console_outside_logger =
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

test "engine: not inside skips matches enclosed by the named class" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.init(gpa, &.{.ts}, "console-outside-logger", kata_console_outside_logger);
    defer f.deinit();

    const src =
        "console.log(1);\n" ++
        "class Logger { log() { console.log(2); } }\n" ++
        "class Other { log() { console.log(3); } }\n";
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("console is only allowed inside Logger", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), diags[1].range.start.line);
}

const kata_no_empty_catch =
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

test "engine: not has fires only when the subtree lacks a match" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-empty-catch", kata_no_empty_catch);
    defer f.deinit();

    const src =
        "try { a(); } catch (e) {}\n" ++
        "try { b(); } catch (e) { rethrow(e); }\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("catch block must handle or rethrow the error", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_statement_call =
    \\rule statement-call {
    \\  lang ts
    \\  match call_expression @match
    \\  where {
    \\    parent @match expression_statement
    \\  }
    \\  emit @match { message "call is a bare statement" }
    \\}
;

test "engine: parent matches the direct parent, not any ancestor" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "statement-call", kata_statement_call);
    defer f.deinit();

    const src =
        "foo();\n" ++
        "bar(baz());\n" ++
        "const x = qux();\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("call is a bare statement", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), diags[1].range.start.column);
}

const kata_no_void =
    \\rule no-void {
    \\  lang ts
    \\  match unary_expression @match {
    \\    operator: "void"
    \\  }
    \\  where {
    \\    text(@match) != "void 0"
    \\    text(@match) != "void(0)"
    \\    not parent @match expression_statement
    \\  }
    \\  emit @match { message "void operator is not allowed - use undefined or remove it" }
    \\}
;

test "engine: no-void flags sub-expression void and exempts statements and void 0" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-void", kata_no_void);
    defer f.deinit();

    const src =
        "if (x === void 42) {\n" ++
        "}\n" ++
        "doSomethingElse(void doSomething());\n" ++
        "const a = void 0;\n" ++
        "const b = void(0);\n" ++
        "void function () { return 1; }();\n" ++
        "void (async () => {})();\n" ++
        "void runPromise();\n" ++
        "const c = void promiseThing;\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    try std.testing.expectEqualStrings("void operator is not allowed - use undefined or remove it", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), diags[1].range.start.line);
    try std.testing.expectEqual(@as(u32, 8), diags[2].range.start.line);
}

const kata_any_of_helper =
    \\rule no-weak-assertions {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      property: property_identifier @name
    \\    }
    \\  }
    \\  where {
    \\    anyOf(text(@name), "toBeNull", "toBeTruthy")
    \\  }
    \\  emit @match { message "weak assertion" }
    \\}
;

test "engine: anyOf helper flags any listed matcher and nothing else" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-weak-assertions", kata_any_of_helper);
    defer f.deinit();

    const src =
        "expect(a).toBeNull();\n" ++
        "expect(b).toBeTruthy();\n" ++
        "expect(c).toEqual(1);\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("weak assertion", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

const kata_in_operator =
    \\rule no-weak-assertions {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      property: property_identifier @name
    \\    }
    \\  }
    \\  where {
    \\    text(@name) in ["toBeNull", "toBeTruthy"]
    \\  }
    \\  emit @match { message "weak assertion" }
    \\}
;

test "engine: in operator flags any listed matcher and nothing else" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-weak-assertions", kata_in_operator);
    defer f.deinit();

    const src =
        "expect(a).toBeNull();\n" ++
        "expect(b).toBeTruthy();\n" ++
        "expect(c).toEqual(1);\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("weak assertion", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

const kata_not_in_operator =
    \\rule allowlist {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      property: property_identifier @name
    \\    }
    \\  }
    \\  where {
    \\    text(@name) not in ["toEqual", "toStrictEqual"]
    \\  }
    \\  emit @match { message "not allowlisted" }
    \\}
;

test "engine: not in operator flags everything outside the set" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "allowlist", kata_not_in_operator);
    defer f.deinit();

    const src =
        "expect(a).toBeNull();\n" ++
        "expect(b).toEqual(1);\n" ++
        "expect(c).toContain(2);\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), diags[1].range.start.line);
}

const kata_too_many_returns =
    \\rule too-many-returns {
    \\  lang ts
    \\  match function_declaration @match
    \\  where {
    \\    count @match return_statement > 3
    \\  }
    \\  emit @match { message "function has too many return statements" }
    \\}
;

test "engine: count compares nested match totals" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "too-many-returns", kata_too_many_returns);
    defer f.deinit();

    const src =
        "function busy(a) {\n" ++
        "  if (a == 1) { return 1; }\n" ++
        "  if (a == 2) { return 2; }\n" ++
        "  if (a == 3) { return 3; }\n" ++
        "  return 4;\n" ++
        "}\n" ++
        "function calm(a) {\n" ++
        "  if (a == 1) { return 1; }\n" ++
        "  return 2;\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("function has too many return statements", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_complex_class =
    \\rule complex-class {
    \\  lang ts
    \\  match class_declaration @match {
    \\    name: type_identifier @name
    \\  }
    \\  where {
    \\    has @match method_definition @method {
    \\      where {
    \\        complexity(@method) > 2
    \\      }
    \\    }
    \\  }
    \\  emit @match { message "class has a complex method" }
    \\}
;

test "engine: has evaluates measures in the nested where" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "complex-class", kata_complex_class);
    defer f.deinit();

    const src =
        "class Busy {\n" ++
        "  work(a, b) {\n" ++
        "    if (a) { return 1; }\n" ++
        "    if (b) { return 2; }\n" ++
        "    return 3;\n" ++
        "  }\n" ++
        "}\n" ++
        "class Calm {\n" ++
        "  work() { return 1; }\n" ++
        "}\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("class has a complex method", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_self_has =
    \\rule self-has {
    \\  lang ts
    \\  match return_statement @match
    \\  where {
    \\    has @match return_statement
    \\  }
    \\  emit @match { message "return contains a return" }
    \\}
;

test "engine: has rejects the same-range self match" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "self-has", kata_self_has);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "function f() { return 1; }\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

const kata_missing_subject =
    \\rule missing-subject {
    \\  lang ts
    \\  match function_declaration @match {
    \\    body: statement_block {
    \\      children: return_statement @rets
    \\    }
    \\  }
    \\  where {
    \\    has @rets call_expression
    \\  }
    \\  emit @match { message "a return calls something" }
    \\}
;

test "engine: a missing subject capture evaluates to false" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "missing-subject", kata_missing_subject);
    defer f.deinit();

    const diags = try f.engine.lint(gpa, "function quiet() { let a = 1; }\nfunction loud() { return call(); }\n", .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

const kata_effect_hooks =
    \\rule effect-hooks {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: identifier @fn
    \\  }
    \\  where {
    \\    startsWith(text(@fn), "use")
    \\    endsWith(text(@fn), "Effect")
    \\    !contains(text(@fn), "Legacy")
    \\  }
    \\  emit @match { message "effect hook call" }
    \\}
;

test "engine: string helper predicates filter matches" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "effect-hooks", kata_effect_hooks);
    defer f.deinit();

    const src =
        "useEffect();\n" ++
        "useLegacyEffect();\n" ++
        "useState();\n" ++
        "runEffect();\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("effect hook call", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_glob_imports =
    \\rule no-internal-imports {
    \\  lang ts
    \\  match import_statement {
    \\    source: string {
    \\      child: string_fragment @src
    \\    }
    \\  }
    \\  where {
    \\    glob(text(@src), "**/internal/**")
    \\  }
    \\  emit @src { message "internal import" }
    \\}
;

test "engine: glob predicate filters matches" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-internal-imports", kata_glob_imports);
    defer f.deinit();

    const src =
        "import { Db } from \"../infra/internal/db\";\n" ++
        "import { Money } from \"./money\";\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("internal import", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_no_early_exit =
    \\rule no-early-exit {
    \\  lang ts
    \\  match function_declaration @match {
    \\    body: statement_block {
    \\      children: return_statement @rets
    \\    }
    \\  }
    \\  where {
    \\    !capture(@rets)
    \\  }
    \\  emit @match { message "function never returns a value" }
    \\}
;

test "engine: capture predicate tests optional capture presence" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-early-exit", kata_no_early_exit);
    defer f.deinit();

    const src =
        "function quiet() { let a = 1; }\n" ++
        "function loud() { return 1; }\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("function never returns a value", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
}

const kata_second_element =
    \\rule second-element {
    \\  lang ts
    \\  match array {
    \\    child: identifier @match
    \\  }
    \\  where {
    \\    position(@match) == 2
    \\  }
    \\  emit @match { message "element {position(@match)} of {siblings(@match)} is flagged" }
    \\}
;

test "engine: position measure selects the nth named sibling" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.init(gpa, &.{.ts}, "second-element", kata_second_element);
    defer f.deinit();

    const src = "const x = [a, b, c];\nconst y = [d];\n";
    const diags = try f.engine.lint(arena.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("element 2 of 3 is flagged", diags[0].message);
    try std.testing.expectEqual(@as(u32, 14), diags[0].range.start.column);
}

const kata_last_element =
    \\rule last-element {
    \\  lang ts
    \\  match array {
    \\    child: identifier @match
    \\  }
    \\  where {
    \\    position(@match) == siblings(@match)
    \\  }
    \\  emit @match { message "last element" }
    \\}
;

test "engine: position equals siblings selects the last named sibling" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "last-element", kata_last_element);
    defer f.deinit();

    const src = "const x = [a, b, c];\nconst y = [d];\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 17), diags[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
    try std.testing.expectEqual(@as(u32, 11), diags[1].range.start.column);
}

const kata_children_constraint =
    \\rule children-constraint {
    \\  lang ts
    \\  match function_declaration @match {
    \\    body: statement_block {
    \\      children: return_statement @ret {
    \\        child: call_expression
    \\      }
    \\    }
    \\  }
    \\  where {
    \\    capture(@ret)
    \\  }
    \\  emit @match { message "a return calls something" }
    \\}
;

test "engine: children relation enforces the nested child pattern" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "children-constraint", kata_children_constraint);
    defer f.deinit();

    const src =
        "function noisy() { return g(); }\n" ++
        "function quiet() { return 1; }\n" ++
        "function late() { return 1; return g(); }\n";
    const diags = try f.engine.lint(gpa, src, .ts, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), diags[1].range.start.line);
}

const kata_repeated_capture =
    \\rule repeated-capture {
    \\  lang ts
    \\  match binary_expression @match {
    \\    left: identifier @side
    \\    right: identifier @side
    \\  }
    \\  where {
    \\    text(@side) == "a"
    \\  }
    \\  emit @match { message "left operand is a" }
    \\}
;

test "engine: a repeated capture evaluates against its first binding" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "repeated-capture", kata_repeated_capture);
    defer f.deinit();

    const flagged = try f.engine.lint(gpa, "a + b;\n", .ts, null);
    defer gpa.free(flagged);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);
    try std.testing.expectEqualStrings("left operand is a", flagged[0].message);

    const clean = try f.engine.lint(gpa, "b + a;\n", .ts, null);
    defer gpa.free(clean);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

const kata_until_boundary =
    \\rule until-boundary {
    \\  lang go
    \\  match defer_statement @match
    \\  where {
    \\    inside @match for_statement until func_literal
    \\  }
    \\  emit @match { message "defer in loop" }
    \\}
;

test "engine: until bounds inside at the boundary kind" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.init(gpa, &.{.go}, "until-boundary", kata_until_boundary);
    defer f.deinit();

    const src =
        "package p\n" ++
        "func direct() {\n" ++
        "\tfor {\n" ++
        "\t\tdefer f()\n" ++
        "\t}\n" ++
        "}\n" ++
        "func guarded(v bool) {\n" ++
        "\tfor {\n" ++
        "\t\tif v {\n" ++
        "\t\t\tdefer f()\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "}\n" ++
        "func spawned() {\n" ++
        "\tfor {\n" ++
        "\t\tfn := func() {\n" ++
        "\t\t\tdefer f()\n" ++
        "\t\t}\n" ++
        "\t\tfn()\n" ++
        "\t}\n" ++
        "}\n";
    const diags = try f.engine.lint(arena.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 3), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 9), diags[1].range.start.line);
}

test "engine: diagnostics carry a rendered fix with the target range" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
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
    var f = try Fixture.init(gpa, &.{.ts}, "prefer-number-parseint", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "const n = parseInt(x);\n", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    const fix = diags[0].fix.?;
    try std.testing.expectEqualStrings("Number.parseInt", fix.replacement);
    try std.testing.expectEqual(diagnostic.Safety.safe, fix.safety);
    try std.testing.expectEqual(@as(u32, 0), fix.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), fix.range.start.column);
    try std.testing.expectEqual(@as(u32, 0), fix.range.end.line);
    try std.testing.expectEqual(@as(u32, 18), fix.range.end.column);
    try std.testing.expectEqual(@as(usize, 0), diags[0].suggestions.len);
}

test "engine: fix templates interpolate capture text" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        \\rule wrap-call {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  emit @match {
        \\    message "wrap it"
        \\    fix unsafe "wrap({text(@fn)})"
        \\  }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "wrap-call", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "const n = parseInt(x);\n", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    const fix = diags[0].fix.?;
    try std.testing.expectEqualStrings("wrap(parseInt)", fix.replacement);
    try std.testing.expectEqual(diagnostic.Safety.unsafe, fix.safety);
    try std.testing.expectEqual(@as(u32, 10), fix.range.start.column);
    try std.testing.expectEqual(@as(u32, 21), fix.range.end.column);
}

test "engine: suggestions render in order with labels" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rule =
        \\rule no-parseint {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  emit @match {
        \\    message "avoid it"
        \\    suggest "qualify" @fn "Number.parseInt"
        \\    suggest "delete the call" ""
        \\  }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "no-parseint", rule);
    defer f.deinit();

    const diags = try f.engine.lint(arena.allocator(), "const n = parseInt(x);\n", .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(?diagnostic.Fix, null), diags[0].fix);
    const suggestions = diags[0].suggestions;
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("qualify", suggestions[0].label);
    try std.testing.expectEqualStrings("Number.parseInt", suggestions[0].replacement);
    try std.testing.expectEqual(@as(u32, 10), suggestions[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 18), suggestions[0].range.end.column);
    try std.testing.expectEqualStrings("delete the call", suggestions[1].label);
    try std.testing.expectEqualStrings("", suggestions[1].replacement);
    try std.testing.expectEqual(@as(u32, 10), suggestions[1].range.start.column);
    try std.testing.expectEqual(@as(u32, 21), suggestions[1].range.end.column);
}

test "engine: hasSyntaxError distinguishes broken from valid source" {
    const gpa = std.testing.allocator;
    const rule =
        \\rule no-console {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match { message "m" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "no-console", rule);
    defer f.deinit();

    try std.testing.expectEqual(false, try f.engine.hasSyntaxError("const x = 1;\n", .ts));
    try std.testing.expectEqual(true, try f.engine.hasSyntaxError("const x = ;\n", .ts));
}

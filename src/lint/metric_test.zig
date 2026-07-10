const std = @import("std");

const language = @import("../core.zig").language;
const test_fixture = @import("../test_fixture.zig");

const Fixture = test_fixture.Fixture;

const comment_rule =
    \\rule no-comments {
    \\  lang ts, tsx, go
    \\  match comment @match
    \\  emit @match { message "no comments" }
    \\}
;

test "metric: function-length flags ts function over threshold" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 3);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function big() {\n" ++
        "  a();\n" ++
        "  b();\n" ++
        "  c();\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("function-length", diags[0].rule_id);
    try std.testing.expectEqualStrings("ts", diags[0].language);
    try std.testing.expectEqualStrings("function length 5 exceeds max 3", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.end.line);
}

test "metric: function at threshold is clean" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 3);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function ok() {\n" ++
        "  a();\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "metric: no configured metrics emits nothing" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function big() {\n" ++
        "  a();\n" ++
        "  b();\n" ++
        "  c();\n" ++
        "  d();\n" ++
        "  e();\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "metric: arrow functions and methods are measured" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "const fn = () => {\n" ++
        "  a();\n" ++
        "  b();\n" ++
        "};\n" ++
        "class C {\n" ++
        "  method() {\n" ++
        "    a();\n" ++
        "    b();\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 5), diags[1].range.start.line);
    try std.testing.expectEqualStrings("function length 4 exceeds max 2", diags[0].message);
    try std.testing.expectEqualStrings("function length 4 exceeds max 2", diags[1].message);
}

test "metric: go functions, methods, and literals are measured" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 3);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "package main\n" ++
        "func long() {\n" ++
        "\ta()\n" ++
        "\tb()\n" ++
        "\tc()\n" ++
        "}\n" ++
        "func (s S) m() {\n" ++
        "\ta()\n" ++
        "\tb()\n" ++
        "\tc()\n" ++
        "}\n" ++
        "var f = func() {\n" ++
        "\ta()\n" ++
        "\tb()\n" ++
        "\tc()\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    for (diags) |d| {
        try std.testing.expectEqualStrings("function-length", d.rule_id);
        try std.testing.expectEqualStrings("go", d.language);
        try std.testing.expectEqualStrings("function length 5 exceeds max 3", d.message);
    }
}

test "metric: tsx arrow component is measured" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.tsx}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "const Comp = () => {\n" ++
        "  const label = useLabel();\n" ++
        "  return <div>{label}</div>;\n" ++
        "};\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .tsx, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("tsx", diags[0].language);
    try std.testing.expectEqualStrings("function length 4 exceeds max 2", diags[0].message);
}

test "metric: complexity counts ts decision points" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.complexity, 7);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function complex(a, b) {\n" ++
        "  if (a && b) {\n" ++
        "    for (const x of b) {\n" ++
        "      a = x ? 1 : 2;\n" ++
        "    }\n" ++
        "  }\n" ++
        "  try {\n" ++
        "    switch (a) {\n" ++
        "      case 1: return 1;\n" ++
        "      case 2: return 2;\n" ++
        "      default: return 3;\n" ++
        "    }\n" ++
        "  } catch (e) {\n" ++
        "    throw e;\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("complexity", diags[0].rule_id);
    try std.testing.expectEqualStrings("cyclomatic complexity 8 exceeds max 7", diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);

    f.engine.metrics.set(.complexity, 8);
    const clean = try f.engine.lint(arena_state.allocator(), src, .ts, null);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "metric: complexity attributes nested functions separately" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.complexity, 1);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function outer() {\n" ++
        "  const inner = () => {\n" ++
        "    if (x) y();\n" ++
        "  };\n" ++
        "  inner();\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("cyclomatic complexity 2 exceeds max 1", diags[0].message);
    try std.testing.expectEqual(@as(u32, 1), diags[0].range.start.line);
}

test "metric: complexity counts go decision points" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.complexity, 5);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "package main\n" ++
        "func f(a int) int {\n" ++
        "\tif a > 0 && a < 10 {\n" ++
        "\t\treturn 1\n" ++
        "\t}\n" ++
        "\tfor i := 0; i < a; i++ {\n" ++
        "\t\tswitch i {\n" ++
        "\t\tcase 1:\n" ++
        "\t\t\ta++\n" ++
        "\t\tcase 2:\n" ++
        "\t\t\ta--\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "\treturn a\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("complexity", diags[0].rule_id);
    try std.testing.expectEqualStrings("cyclomatic complexity 6 exceeds max 5", diags[0].message);
}

test "metric: nesting depth flags construct beyond threshold" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.nesting_depth, 3);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function deep(a) {\n" ++
        "  if (a) {\n" ++
        "    for (;;) {\n" ++
        "      while (a) {\n" ++
        "        if (a) b();\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("nesting-depth", diags[0].rule_id);
    try std.testing.expectEqualStrings("nesting depth 4 exceeds max 3", diags[0].message);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);

    f.engine.metrics.set(.nesting_depth, 4);
    const clean = try f.engine.lint(arena_state.allocator(), src, .ts, null);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "metric: else-if chains do not increase nesting depth" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.ts}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.nesting_depth, 2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "function chain(a) {\n" ++
        "  if (a === 1) {\n" ++
        "    b();\n" ++
        "  } else if (a === 2) {\n" ++
        "    if (a) c();\n" ++
        "  }\n" ++
        "}\n";
    const clean = try f.engine.lint(arena_state.allocator(), src, .ts, null);
    try std.testing.expectEqual(@as(usize, 0), clean.len);

    f.engine.metrics.set(.nesting_depth, 1);
    const diags = try f.engine.lint(arena_state.allocator(), src, .ts, null);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("nesting depth 2 exceeds max 1", diags[0].message);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
}

test "metric: go switch nests via the switch statement" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.nesting_depth, 2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "package main\n" ++
        "func f(a int) {\n" ++
        "\tif a > 0 {\n" ++
        "\t\tswitch a {\n" ++
        "\t\tcase 1:\n" ++
        "\t\t\tif a == 1 {\n" ++
        "\t\t\t\tb()\n" ++
        "\t\t\t}\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("nesting-depth", diags[0].rule_id);
    try std.testing.expectEqualStrings("nesting depth 3 exceeds max 2", diags[0].message);
    try std.testing.expectEqual(@as(u32, 5), diags[0].range.start.line);
}

test "metric: rule diagnostics and metric diagnostics coexist" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa, &.{.go}, "no-comments", comment_rule);
    defer f.deinit();
    f.engine.metrics.set(.function_length, 2);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const src =
        "package main\n" ++
        "// a comment\n" ++
        "func long() {\n" ++
        "\ta()\n" ++
        "\tb()\n" ++
        "}\n";
    const diags = try f.engine.lint(arena_state.allocator(), src, .go, null);

    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("no-comments", diags[0].rule_id);
    try std.testing.expectEqualStrings("function-length", diags[1].rule_id);
}

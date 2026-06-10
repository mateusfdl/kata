const std = @import("std");

const language = @import("language.zig");
const test_fixture = @import("../test_fixture.zig");

const Fixture = test_fixture.Fixture;

const comment_rule = "((comment) @match (#set! message \"no comments\"))\n";

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

test "metric: scm diagnostics and metric diagnostics coexist" {
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

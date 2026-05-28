const std = @import("std");
const language = @import("language.zig");
const test_fixture = @import("test_fixture.zig");

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

const Fixture = test_fixture.Fixture;

fn newFixture(allocator: std.mem.Allocator, langs: []const language.Name) !*Fixture {
    return Fixture.init(allocator, langs, "no-as-any", no_as_any_rule);
}

test "engine: detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const x = (foo[0] as any).bar;";
    const diags = try f.engine.lint(gpa, src, .ts);
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
    const diags = try f.engine.lint(gpa, src, .ts);
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
        const diags = try f.engine.lint(gpa, src, .ts);
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

    const first = try f.engine.lint(gpa, src, .go);
    defer gpa.free(first);
    try std.testing.expectEqual(@as(usize, 0), first.len);

    const second = try f.engine.lint(gpa, src, .go);
    defer gpa.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "engine: tsx detects `as any`" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.tsx});
    defer f.deinit();

    const src = "const Comp = () => <div>{(props as any).label}</div>;";
    const diags = try f.engine.lint(gpa, src, .tsx);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("tsx", diags[0].language);
}

test "engine: multiple violations across lines" {
    const gpa = std.testing.allocator;
    var f = try newFixture(gpa, &.{.ts});
    defer f.deinit();

    const src = "const a = x as any;\nconst b = y as any;\n";
    const diags = try f.engine.lint(gpa, src, .ts);
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
    const diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("ts", diags[0].language);

    const tsx_diags = try f.engine.lint(gpa, src, .tsx);
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

    const ts_diags = try f.engine.lint(gpa, src, .ts);
    defer gpa.free(ts_diags);
    try std.testing.expectEqual(@as(usize, 1), ts_diags.len);
    try std.testing.expectEqualStrings("no-weak-assertions", ts_diags[0].rule_id);
    try std.testing.expectEqualStrings("weak assertion - use .toEqual() with explicit values", ts_diags[0].message);

    const tsx_diags = try f.engine.lint(gpa, src, .tsx);
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
    const diags = try f.engine.lint(gpa, src, .go);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("no-swallowed-errors", diags[0].rule_id);
    try std.testing.expectEqualStrings("go", diags[0].language);
    try std.testing.expectEqualStrings(
        "blank identifier discarding function return - errors must be handled explicitly",
        diags[0].message,
    );
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
    const diags = try f.engine.lint(gpa, src, .go);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    for (diags) |d| {
        try std.testing.expectEqualStrings("no-console", d.rule_id);
        try std.testing.expectEqualStrings("console output is not allowed - use proper instrumentation", d.message);
    }
}

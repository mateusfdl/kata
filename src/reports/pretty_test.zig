const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

fn diag(rule_id: []const u8, message: []const u8, range: lint.diagnostic.Range, severity: lint.diagnostic.Severity) lint.diagnostic.Diagnostic {
    return .{
        .rule_id = rule_id,
        .language = "ts",
        .message = message,
        .range = range,
        .severity = severity,
    };
}

fn render(source: []const u8, d: lint.diagnostic.Diagnostic, out: *std.Io.Writer.Allocating) !void {
    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", source, &.{d});
}

test "pretty: frames a violation with two context lines each side" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "one\ntwo\nthree\nfour\n  console.log(1);\nsix\nseven\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 4, .column = 2 },
        .end = .{ .line = 4, .column = 13 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:5:3 [no-console]\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "  3 | three\n" ++
            "  4 | four\n" ++
            "> 5 |   console.log(1);\n" ++
            "    |   ^^^^^^^^^^^\n" ++
            "  6 | six\n" ++
            "  7 | seven\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: violation on the first line has no leading context" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\nafter1\nafter2\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console]\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "> 1 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "  2 | after1\n" ++
            "  3 | after2\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: violation on the last line has no trailing context" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "a\nb\nconsole.log(1);\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 2, .column = 0 },
        .end = .{ .line = 2, .column = 15 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:3:1 [no-console]\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "  1 | a\n" ++
            "  2 | b\n" ++
            "> 3 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: tabs before a violation align the underline with the rendered source" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "func main() {\n\t\t_, err := send()\n}\n";
    const d = diag("no-swallowed-errors", "blank identifier discarding function return", .{
        .start = .{ .line = 1, .column = 2 },
        .end = .{ .line = 1, .column = 8 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:2:3 [no-swallowed-errors]\n" ++
            "\n" ++
            "  x blank identifier discarding function return\n" ++
            "\n" ++
            "  1 | func main() {\n" ++
            "> 2 |         _, err := send()\n" ++
            "    |         ^^^^^^\n" ++
            "  3 | }\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: tabs inside a violation keep caret width aligned" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "value\t:= call()\n";
    const d = diag("assignment", "assignment is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 8 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [assignment]\n" ++
            "\n" ++
            "  x assignment is not allowed\n" ++
            "\n" ++
            "> 1 | value   := call()\n" ++
            "    | ^^^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: multi-line node underlines to the end of the first line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "foo(\n  bar,\n);\n";
    const d = diag("no-foo", "foo is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 2, .column = 2 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-foo]\n" ++
            "\n" ++
            "  x foo is not allowed\n" ++
            "\n" ++
            "> 1 | foo(\n" ++
            "    | ^^^^\n" ++
            "  2 |   bar,\n" ++
            "  3 | );\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: warn severity uses the bang marker" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .warn);
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console]\n" ++
            "\n" ++
            "  ! console is not allowed\n" ++
            "\n" ++
            "> 1 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: gutter aligns double-digit line numbers" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nconsole.log(1);\nl10\nl11\nl12\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 8, .column = 0 },
        .end = .{ .line = 8, .column = 15 },
    }, .@"error");
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:9:1 [no-console]\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "   7 | l7\n" ++
            "   8 | l8\n" ++
            ">  9 | console.log(1);\n" ++
            "     | ^^^^^^^^^^^^^^^\n" ++
            "  10 | l10\n" ++
            "  11 | l11\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: location includes innermost enclosing contexts" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\n";
    var d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    d.context = &.{
        .{
            .kind = .namespace,
            .name = "App",
            .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 5, .column = 1 } },
        },
        .{
            .kind = .class,
            .name = "Editor",
            .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 4, .column = 1 } },
        },
        .{
            .kind = .method,
            .name = "render",
            .range = .{ .start = .{ .line = 1, .column = 2 }, .end = .{ .line = 3, .column = 3 } },
        },
    };
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console] in method render of class Editor\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "> 1 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: location includes one enclosing context" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\n";
    var d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    d.context = &.{.{
        .kind = .function,
        .name = "handler",
        .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 15 } },
    }};
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console] in function handler\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "> 1 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: project violations fall back to the plain line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &out.writer } };
    const d = diag("domain-no-infra", "import denied", .{
        .start = .{ .line = 0, .column = 20 },
        .end = .{ .line = 0, .column = 33 },
    }, .@"error");
    try reporter.project(&.{.{ .path = "src/domain/user.ts", .diagnostic = d }});

    try std.testing.expectEqualStrings(
        "src/domain/user.ts:1:21 [domain-no-infra] import denied\n",
        out.written(),
    );
}

test "pretty: finish renders the summary" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &out.writer } };
    try reporter.finish(.{ .files = 3, .violations = 2, .warnings = 1 });

    try std.testing.expectEqualStrings("checked 3 files, 2 violations, 1 warnings\n", out.written());
}

test "pretty: color dims enclosing context" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\n";
    var d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    d.context = &.{.{
        .kind = .function,
        .name = "handler",
        .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 15 } },
    }};
    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &out.writer, .color = true } };
    try reporter.file("src/app.ts", source, &.{d});

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console]\x1b[2m in function handler\x1b[0m\n" ++
            "\n" ++
            "  \x1b[31mx console is not allowed\x1b[0m\n" ++
            "\n" ++
            "\x1b[31m>\x1b[0m 1 | console.log(1);\n" ++
            "    | \x1b[31m^^^^^^^^^^^^^^^\x1b[0m\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: color renders severity and carets in ansi codes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "console.log(1);\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &out.writer, .color = true } };
    try reporter.file("src/app.ts", source, &.{d});

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console]\n" ++
            "\n" ++
            "  \x1b[31mx console is not allowed\x1b[0m\n" ++
            "\n" ++
            "\x1b[31m>\x1b[0m 1 | console.log(1);\n" ++
            "    | \x1b[31m^^^^^^^^^^^^^^^\x1b[0m\n" ++
            "\n",
        out.written(),
    );
}

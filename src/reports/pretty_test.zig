const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

const FlushSink = struct {
    interface: std.Io.Writer = .{ .vtable = &vtable, .buffer = &.{} },
    buffer: [4096]u8 = undefined,
    output: [4096]u8 = undefined,
    output_len: usize = 0,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn bind(self: *FlushSink) void {
        self.interface.buffer = &self.buffer;
    }

    fn written(self: *const FlushSink) []const u8 {
        return self.output[0..self.output_len];
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlushSink = @alignCast(@fieldParentPtr("interface", writer));
        const buffered = writer.buffered();
        if (self.output_len + buffered.len > self.output.len) return error.WriteFailed;

        @memcpy(self.output[self.output_len..][0..buffered.len], buffered);
        self.output_len += buffered.len;
        writer.end = 0;

        return std.Io.Writer.countSplat(data, splat);
    }
};

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
    try reporter.finish(.{ .files = 3, .violations = 2, .warnings = 1 }, &.{});

    try std.testing.expectEqualStrings("checked 3 files, 2 violations, 1 warnings\n", out.written());
}

test "pretty: file flushes a complete report" {
    var sink: FlushSink = .{};
    sink.bind();

    const source = "console.log(1);\n";
    const d = diag("no-console", "console is not allowed", .{
        .start = .{ .line = 0, .column = 0 },
        .end = .{ .line = 0, .column = 15 },
    }, .@"error");
    var reporter: reports.Reporter = .{ .pretty = .{ .writer = &sink.interface } };
    try reporter.file("src/app.ts", source, &.{d});

    try std.testing.expectEqualStrings(
        "src/app.ts:1:1 [no-console]\n" ++
            "\n" ++
            "  x console is not allowed\n" ++
            "\n" ++
            "> 1 | console.log(1);\n" ++
            "    | ^^^^^^^^^^^^^^^\n" ++
            "\n",
        sink.written(),
    );
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

test "pretty: renders the fix line under the message" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "const n = parseInt(x);\n";
    var d = diag("prefer-number-parseint", "Prefer Number.parseInt", .{
        .start = .{ .line = 0, .column = 10 },
        .end = .{ .line = 0, .column = 18 },
    }, .@"error");
    d.fix = .{
        .range = .{ .start = .{ .line = 0, .column = 10 }, .end = .{ .line = 0, .column = 18 } },
        .replacement = "Number.parseInt",
        .safety = .safe,
    };
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:11 [prefer-number-parseint]\n" ++
            "\n" ++
            "  x Prefer Number.parseInt\n" ++
            "  fix: Number.parseInt\n" ++
            "\n" ++
            "> 1 | const n = parseInt(x);\n" ++
            "    |           ^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: marks unsafe fixes and renders deletions as remove" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "const n = parseInt(x);\n";
    var d = diag("no-parseint", "no parseInt", .{
        .start = .{ .line = 0, .column = 10 },
        .end = .{ .line = 0, .column = 18 },
    }, .@"error");
    d.fix = .{
        .range = .{ .start = .{ .line = 0, .column = 10 }, .end = .{ .line = 0, .column = 22 } },
        .replacement = "",
        .safety = .unsafe,
    };
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:11 [no-parseint]\n" ++
            "\n" ++
            "  x no parseInt\n" ++
            "  fix: remove (unsafe)\n" ++
            "\n" ++
            "> 1 | const n = parseInt(x);\n" ++
            "    |           ^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

test "pretty: renders suggestion lines with labels" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const source = "const y = v as any;\n";
    var d = diag("no-as-any", "as any is not allowed", .{
        .start = .{ .line = 0, .column = 10 },
        .end = .{ .line = 0, .column = 18 },
    }, .@"error");
    d.suggestions = &.{
        .{
            .label = "use unknown",
            .range = .{ .start = .{ .line = 0, .column = 15 }, .end = .{ .line = 0, .column = 18 } },
            .replacement = "unknown",
        },
        .{
            .label = "drop the cast",
            .range = .{ .start = .{ .line = 0, .column = 11 }, .end = .{ .line = 0, .column = 18 } },
            .replacement = "",
        },
    };
    try render(source, d, &out);

    try std.testing.expectEqualStrings(
        "src/app.ts:1:11 [no-as-any]\n" ++
            "\n" ++
            "  x as any is not allowed\n" ++
            "  suggest use unknown: unknown\n" ++
            "  suggest drop the cast: remove\n" ++
            "\n" ++
            "> 1 | const y = v as any;\n" ++
            "    |           ^^^^^^^^\n" ++
            "\n",
        out.written(),
    );
}

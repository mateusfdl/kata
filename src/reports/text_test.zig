const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

fn diagnostic(severity: lint.diagnostic.Severity) lint.diagnostic.Diagnostic {
    return .{
        .rule_id = "no-console",
        .language = "ts",
        .message = "console is not allowed",
        .range = .{ .start = .{ .line = 4, .column = 2 }, .end = .{ .line = 4, .column = 9 } },
        .severity = severity,
    };
}

test "text: file renders one line per diagnostic" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "const x = 1;\n", &.{
        diagnostic(.@"error"),
        diagnostic(.warn),
    });

    try std.testing.expectEqualStrings(
        "src/app.ts:5:3 [no-console] console is not allowed\n" ++
            "src/app.ts:5:3 warn [no-console] console is not allowed\n",
        out.written(),
    );
}

test "text: project renders the violation path" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    try reporter.project(&.{.{ .path = "src/service.ts", .diagnostic = diagnostic(.@"error") }});

    try std.testing.expectEqualStrings(
        "src/service.ts:5:3 [no-console] console is not allowed\n",
        out.written(),
    );
}

test "text: finish renders the summary" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .text = .{ .writer = &out.writer } };
    try reporter.finish(.{ .files = 3, .violations = 2, .warnings = 1 });

    try std.testing.expectEqualStrings("checked 3 files, 2 violations, 1 warnings\n", out.written());
}

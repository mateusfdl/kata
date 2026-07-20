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

const diagnostic_json =
    "{\"rule_id\":\"no-console\",\"language\":\"ts\",\"message\":\"console is not allowed\"," ++
    "\"range\":{\"start\":{\"line\":4,\"column\":2},\"end\":{\"line\":4,\"column\":9}}," ++
    "\"severity\":\"error\",\"demoted\":false,\"maturity\":\"stable\",\"fingerprint\":\"\",\"context\":[]," ++
    "\"fix\":null,\"suggestions\":[]}";

test "json: clean run renders empty files and the summary" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "const x = 1;\n", &.{});
    try reporter.finish(.{ .files = 1, .violations = 0, .warnings = 0 });

    try std.testing.expectEqualStrings(
        "{\"files\":[],\"summary\":{\"files\":1,\"violations\":0,\"warnings\":0}}\n",
        out.written(),
    );
}

test "json: files with diagnostics render as entries" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/clean.ts", "const x = 1;\n", &.{});
    try reporter.file("src/app.ts", "console.log(1);\n", &.{diagnostic(.@"error")});
    try reporter.file("src/other.ts", "console.log(2);\n", &.{diagnostic(.@"error")});
    try reporter.finish(.{ .files = 3, .violations = 2, .warnings = 0 });

    try std.testing.expectEqualStrings(
        "{\"files\":[" ++
            "{\"path\":\"src/app.ts\",\"diagnostics\":[" ++ diagnostic_json ++ "]}," ++
            "{\"path\":\"src/other.ts\",\"diagnostics\":[" ++ diagnostic_json ++ "]}" ++
            "],\"summary\":{\"files\":3,\"violations\":2,\"warnings\":0}}\n",
        out.written(),
    );
}

test "json: project violations render as entries" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.project(&.{.{ .path = "src/service.ts", .diagnostic = diagnostic(.@"error") }});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expectEqualStrings(
        "{\"files\":[" ++
            "{\"path\":\"src/service.ts\",\"diagnostics\":[" ++ diagnostic_json ++ "]}" ++
            "],\"summary\":{\"files\":1,\"violations\":1,\"warnings\":0}}\n",
        out.written(),
    );
}

test "json: populated context renders its complete shape" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var d = diagnostic(.@"error");
    d.context = &.{.{
        .kind = .method,
        .name = "render",
        .range = .{ .start = .{ .line = 1, .column = 2 }, .end = .{ .line = 3, .column = 3 } },
    }};

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "", &.{d});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expectEqualStrings(
        "{\"files\":[{\"path\":\"src/app.ts\",\"diagnostics\":[" ++
            "{\"rule_id\":\"no-console\",\"language\":\"ts\",\"message\":\"console is not allowed\"," ++
            "\"range\":{\"start\":{\"line\":4,\"column\":2},\"end\":{\"line\":4,\"column\":9}}," ++
            "\"severity\":\"error\",\"demoted\":false,\"maturity\":\"stable\",\"fingerprint\":\"\",\"context\":[" ++
            "{\"kind\":\"method\",\"name\":\"render\",\"range\":{\"start\":{\"line\":1,\"column\":2}," ++
            "\"end\":{\"line\":3,\"column\":3}}}],\"fix\":null,\"suggestions\":[]}]}]," ++
            "\"summary\":{\"files\":1,\"violations\":1,\"warnings\":0}}\n",
        out.written(),
    );
}

test "json: warn severity serializes as warn" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "console.log(1);\n", &.{diagnostic(.warn)});
    try reporter.finish(.{ .files = 1, .violations = 0, .warnings = 1 });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"severity\":\"warn\"") != null);
}

test "json: experimental maturity serializes as experimental" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var d = diagnostic(.@"error");
    d.maturity = .experimental;

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "console.log(1);\n", &.{d});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"maturity\":\"experimental\"") != null);
}

test "json: populated fix and suggestions render their complete shape" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var d = diagnostic(.@"error");
    d.fix = .{
        .range = .{ .start = .{ .line = 4, .column = 2 }, .end = .{ .line = 4, .column = 9 } },
        .replacement = "Number.parseInt",
        .safety = .safe,
    };
    d.suggestions = &.{.{
        .label = "use unknown",
        .range = .{ .start = .{ .line = 4, .column = 2 }, .end = .{ .line = 4, .column = 9 } },
        .replacement = "unknown",
    }};

    var reporter: reports.Reporter = .{ .json = .{ .writer = &out.writer } };
    try reporter.file("src/app.ts", "", &.{d});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expectEqualStrings(
        "{\"files\":[{\"path\":\"src/app.ts\",\"diagnostics\":[" ++
            "{\"rule_id\":\"no-console\",\"language\":\"ts\",\"message\":\"console is not allowed\"," ++
            "\"range\":{\"start\":{\"line\":4,\"column\":2},\"end\":{\"line\":4,\"column\":9}}," ++
            "\"severity\":\"error\",\"demoted\":false,\"maturity\":\"stable\",\"fingerprint\":\"\",\"context\":[]," ++
            "\"fix\":{\"range\":{\"start\":{\"line\":4,\"column\":2},\"end\":{\"line\":4,\"column\":9}}," ++
            "\"replacement\":\"Number.parseInt\",\"safety\":\"safe\"}," ++
            "\"suggestions\":[{\"label\":\"use unknown\"," ++
            "\"range\":{\"start\":{\"line\":4,\"column\":2},\"end\":{\"line\":4,\"column\":9}}," ++
            "\"replacement\":\"unknown\"}]}]}]," ++
            "\"summary\":{\"files\":1,\"violations\":1,\"warnings\":0}}\n",
        out.written(),
    );
}

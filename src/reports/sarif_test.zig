const std = @import("std");

const build_options = @import("build_options");
const lint = @import("engine");
const reports = @import("../reports.zig");

fn diagnostic(severity: lint.diagnostic.Severity) lint.diagnostic.Diagnostic {
    return .{
        .rule_id = "no-console",
        .language = "ts",
        .message = "console is not allowed",
        .range = .{ .start = .{ .line = 4, .column = 2 }, .end = .{ .line = 4, .column = 9 } },
        .severity = severity,
        .fingerprint = "aaaa1111",
    };
}

fn sarifReporter(out: *std.Io.Writer.Allocating) reports.Reporter {
    return .{ .sarif = .{ .writer = &out.writer, .gpa = std.testing.allocator } };
}

fn document(comptime results: []const u8, comptime rules: []const u8) []const u8 {
    return "{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\"," ++
        "\"runs\":[{\"results\":[" ++ results ++ "]," ++
        "\"tool\":{\"driver\":{\"name\":\"kata\",\"semanticVersion\":\"" ++ build_options.version ++ "\"," ++
        "\"rules\":[" ++ rules ++ "]}}}]}\n";
}

const error_result =
    "{\"ruleId\":\"no-console\",\"ruleIndex\":0,\"level\":\"error\"," ++
    "\"message\":{\"text\":\"console is not allowed\"}," ++
    "\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"src/app.ts\"}," ++
    "\"region\":{\"startLine\":5,\"startColumn\":3,\"endLine\":5,\"endColumn\":10}}}]," ++
    "\"partialFingerprints\":{\"kataFingerprint/v1\":\"aaaa1111\"}}";

test "sarif: clean run renders empty results and rules" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter = sarifReporter(&out);
    try reporter.file("src/app.ts", "const x = 1;\n", &.{});
    try reporter.finish(.{ .files = 1, .violations = 0, .warnings = 0 });

    try std.testing.expectEqualStrings(document("", ""), out.written());
}

test "sarif: an error and a demoted warning share one descriptor at level error" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var demoted = diagnostic(.warn);
    demoted.demoted = true;
    demoted.range = .{ .start = .{ .line = 7, .column = 0 }, .end = .{ .line = 7, .column = 7 } };
    demoted.fingerprint = "bbbb2222";

    var reporter = sarifReporter(&out);
    try reporter.file("src/app.ts", "", &.{ diagnostic(.@"error"), demoted });
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 1 });

    try std.testing.expectEqualStrings(document(
        error_result ++ "," ++
            "{\"ruleId\":\"no-console\",\"ruleIndex\":0,\"level\":\"warning\"," ++
            "\"message\":{\"text\":\"console is not allowed\"}," ++
            "\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"src/app.ts\"}," ++
            "\"region\":{\"startLine\":8,\"startColumn\":1,\"endLine\":8,\"endColumn\":8}}}]," ++
            "\"partialFingerprints\":{\"kataFingerprint/v1\":\"bbbb2222\"}}",
        "{\"id\":\"no-console\",\"defaultConfiguration\":{\"level\":\"error\"}}",
    ), out.written());
}

test "sarif: descriptors keep first-appearance order across files" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var other = diagnostic(.warn);
    other.rule_id = "no-as-any";
    other.message = "as any is not allowed";
    other.fingerprint = "cccc3333";

    var reporter = sarifReporter(&out);
    try reporter.file("src/app.ts", "", &.{diagnostic(.@"error")});
    try reporter.file("src/other.ts", "", &.{other});
    try reporter.finish(.{ .files = 2, .violations = 1, .warnings = 1 });

    try std.testing.expectEqualStrings(document(
        error_result ++ "," ++
            "{\"ruleId\":\"no-as-any\",\"ruleIndex\":1,\"level\":\"warning\"," ++
            "\"message\":{\"text\":\"as any is not allowed\"}," ++
            "\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"src/other.ts\"}," ++
            "\"region\":{\"startLine\":5,\"startColumn\":3,\"endLine\":5,\"endColumn\":10}}}]," ++
            "\"partialFingerprints\":{\"kataFingerprint/v1\":\"cccc3333\"}}",
        "{\"id\":\"no-console\",\"defaultConfiguration\":{\"level\":\"error\"}}," ++
            "{\"id\":\"no-as-any\",\"defaultConfiguration\":{\"level\":\"warning\"}}",
    ), out.written());
}

test "sarif: project violations render as results" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var reporter = sarifReporter(&out);
    try reporter.project(&.{.{ .path = "src/app.ts", .diagnostic = diagnostic(.@"error") }});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expectEqualStrings(document(
        error_result,
        "{\"id\":\"no-console\",\"defaultConfiguration\":{\"level\":\"error\"}}",
    ), out.written());
}

test "sarif: empty fingerprint omits partialFingerprints" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var d = diagnostic(.@"error");
    d.fingerprint = "";

    var reporter = sarifReporter(&out);
    try reporter.file("src/app.ts", "", &.{d});
    try reporter.finish(.{ .files = 1, .violations = 1, .warnings = 0 });

    try std.testing.expectEqualStrings(document(
        "{\"ruleId\":\"no-console\",\"ruleIndex\":0,\"level\":\"error\"," ++
            "\"message\":{\"text\":\"console is not allowed\"}," ++
            "\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"src/app.ts\"}," ++
            "\"region\":{\"startLine\":5,\"startColumn\":3,\"endLine\":5,\"endColumn\":10}}}]}",
        "{\"id\":\"no-console\",\"defaultConfiguration\":{\"level\":\"error\"}}",
    ), out.written());
}

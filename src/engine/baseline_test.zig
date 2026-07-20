const std = @import("std");

const lint = @import("engine");
const baseline = lint.baseline;
const diagnostic = lint.diagnostic;

fn finding(
    rule_id: []const u8,
    severity: diagnostic.Severity,
    fp: []const u8,
    start_line: u32,
    start_column: u32,
    end_line: u32,
    end_column: u32,
) diagnostic.Diagnostic {
    return .{
        .rule_id = rule_id,
        .language = "ts",
        .message = "message",
        .range = .{
            .start = .{ .line = start_line, .column = start_column },
            .end = .{ .line = end_line, .column = end_column },
        },
        .severity = severity,
        .fingerprint = fp,
    };
}

const function_context = [_]diagnostic.Context{.{
    .kind = .function,
    .name = "f",
    .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 33 } },
}};

test "baseline: identical fingerprint demotes and flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{finding("rule", .@"error", "aaa", 0, 0, 0, 3)};
    const before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "aaa", 0, 0, 0, 3)};

    const demoted = try baseline.demote(arena_state.allocator(), "bad\n", &diagnostics, "bad\n", &before);

    try std.testing.expectEqual(@as(usize, 1), demoted);
    try std.testing.expectEqual(diagnostic.Severity.warn, diagnostics[0].severity);
    try std.testing.expectEqual(true, diagnostics[0].demoted);
}

test "baseline: moved duplicate demotes on rule and span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{finding("rule", .@"error", "fp-current", 1, 0, 1, 3)};
    const before = [_]diagnostic.Diagnostic{finding("rule", .warn, "fp-before", 0, 0, 0, 3)};

    const demoted = try baseline.demote(arena_state.allocator(), "ok\nbad\n", &diagnostics, "bad\nok\n", &before);

    try std.testing.expectEqual(@as(usize, 1), demoted);
    try std.testing.expectEqual(diagnostic.Severity.warn, diagnostics[0].severity);
    try std.testing.expectEqual(true, diagnostics[0].demoted);
}

test "baseline: changed span inside an intact block demotes on block hash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = "function f() { alpha(); beta(); }";

    var diagnostics = [_]diagnostic.Diagnostic{finding("rule", .@"error", "fp-current", 0, 15, 0, 20)};
    diagnostics[0].context = &function_context;
    var before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "fp-before", 0, 15, 0, 22)};
    before[0].context = &function_context;

    const demoted = try baseline.demote(arena_state.allocator(), source, &diagnostics, source, &before);

    try std.testing.expectEqual(@as(usize, 1), demoted);
    try std.testing.expectEqual(diagnostic.Severity.warn, diagnostics[0].severity);
    try std.testing.expectEqual(true, diagnostics[0].demoted);
}

test "baseline: ambiguous block hash never demotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const source = "function f() { alpha(); beta(); }";

    var diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", .@"error", "fp-a", 0, 15, 0, 20),
        finding("rule", .@"error", "fp-b", 0, 24, 0, 28),
    };
    diagnostics[0].context = &function_context;
    diagnostics[1].context = &function_context;
    var before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "fp-c", 0, 15, 0, 22)};
    before[0].context = &function_context;

    const demoted = try baseline.demote(arena_state.allocator(), source, &diagnostics, source, &before);

    try std.testing.expectEqual(@as(usize, 0), demoted);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diagnostics[0].severity);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diagnostics[1].severity);
    try std.testing.expectEqual(false, diagnostics[0].demoted);
    try std.testing.expectEqual(false, diagnostics[1].demoted);
}

test "baseline: warnings are never candidates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{finding("rule", .warn, "aaa", 0, 0, 0, 3)};
    const before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "aaa", 0, 0, 0, 3)};

    const demoted = try baseline.demote(arena_state.allocator(), "bad\n", &diagnostics, "bad\n", &before);

    try std.testing.expectEqual(@as(usize, 0), demoted);
    try std.testing.expectEqual(diagnostic.Severity.warn, diagnostics[0].severity);
    try std.testing.expectEqual(false, diagnostics[0].demoted);
}

test "baseline: unmatched current error stands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{finding("rule", .@"error", "aaa", 0, 0, 0, 3)};
    const before = [_]diagnostic.Diagnostic{finding("other", .@"error", "bbb", 0, 0, 0, 2)};

    const demoted = try baseline.demote(arena_state.allocator(), "bad\n", &diagnostics, "ok\n", &before);

    try std.testing.expectEqual(@as(usize, 0), demoted);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diagnostics[0].severity);
    try std.testing.expectEqual(false, diagnostics[0].demoted);
}

test "baseline: unmatched baseline finding expires silently" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{};
    const before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "aaa", 0, 0, 0, 3)};

    const demoted = try baseline.demote(arena_state.allocator(), "ok\n", &diagnostics, "bad\n", &before);

    try std.testing.expectEqual(@as(usize, 0), demoted);
}

test "baseline: each baseline finding demotes at most one error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", .@"error", "fp-a", 0, 0, 0, 3),
        finding("rule", .@"error", "fp-b", 0, 4, 0, 7),
    };
    const before = [_]diagnostic.Diagnostic{finding("rule", .@"error", "fp-c", 0, 0, 0, 3)};

    const demoted = try baseline.demote(arena_state.allocator(), "bad bad", &diagnostics, "bad", &before);

    try std.testing.expectEqual(@as(usize, 1), demoted);
    try std.testing.expectEqual(diagnostic.Severity.warn, diagnostics[0].severity);
    try std.testing.expectEqual(true, diagnostics[0].demoted);
    try std.testing.expectEqual(diagnostic.Severity.@"error", diagnostics[1].severity);
    try std.testing.expectEqual(false, diagnostics[1].demoted);
}

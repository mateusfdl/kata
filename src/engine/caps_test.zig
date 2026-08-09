const std = @import("std");

const caps = @import("engine").caps;
const diagnostic = @import("engine").diagnostic;
const rule = @import("engine").rule;

fn at(rule_id: []const u8, line: u32) diagnostic.Diagnostic {
    return .{
        .rule_id = rule_id,
        .language = "ts",
        .message = "violation",
        .range = .{ .start = .{ .line = line, .column = 0 }, .end = .{ .line = line, .column = 4 } },
    };
}

fn flood(arena: std.mem.Allocator, rule_id: []const u8, count: u32) ![]diagnostic.Diagnostic {
    const out = try arena.alloc(diagnostic.Diagnostic, count);
    for (out, 0..) |*d, line| d.* = at(rule_id, @intCast(line));
    return out;
}

test "caps: a rule under the cap passes through untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try flood(arena.allocator(), "no-as-any", 4);
    const out = try caps.apply(arena.allocator(), input, &.{}, 5);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    for (out) |d| try std.testing.expectEqual(false, d.capped);
}

test "caps: a rule exactly at the cap passes through untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try flood(arena.allocator(), "no-as-any", 5);
    const out = try caps.apply(arena.allocator(), input, &.{}, 5);

    try std.testing.expectEqual(@as(usize, 5), out.len);
}

test "caps: overflow keeps the first three and appends one synthetic diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try flood(arena.allocator(), "no-as-any", 7);
    const out = try caps.apply(arena.allocator(), input, &.{}, 5);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), out[1].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), out[2].range.start.line);

    const synthetic = out[3];
    try std.testing.expectEqualStrings("no-as-any", synthetic.rule_id);
    try std.testing.expectEqualStrings(
        "rule no-as-any fired 7 times in this file; showing 3, suppressed 4; a flood usually means a broken pattern or wrong scope",
        synthetic.message,
    );
    try std.testing.expectEqual(@as(u32, 0), synthetic.range.start.line);
    try std.testing.expectEqual(diagnostic.Severity.@"error", synthetic.severity);
    try std.testing.expectEqual(true, synthetic.capped);
}

test "caps: a per-rule override beats the default cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const settings = [_]rule.RuleSetting{.{ .lang = .ts, .id = "no-as-any", .max_matches = 2 }};
    const input = try flood(arena.allocator(), "no-as-any", 5);
    const out = try caps.apply(arena.allocator(), input, &settings, 25);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqual(true, out[3].capped);
}

test "caps: max-matches zero disables the cap for the rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const settings = [_]rule.RuleSetting{.{ .lang = .ts, .id = "no-as-any", .max_matches = 0 }};
    const input = try flood(arena.allocator(), "no-as-any", 30);
    const out = try caps.apply(arena.allocator(), input, &settings, 25);

    try std.testing.expectEqual(@as(usize, 30), out.len);
}

test "caps: a Go setting does not cap a TypeScript diagnostic with the same rule ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const settings = [_]rule.RuleSetting{.{ .lang = .go, .id = "shared", .max_matches = 2 }};
    const input = try flood(arena.allocator(), "shared", 5);
    const out = try caps.apply(arena.allocator(), input, &settings, 0);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    for (out) |d| try std.testing.expectEqual(false, d.capped);
}

test "caps: a project setting does not cap a language diagnostic with the same rule ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const settings = [_]rule.RuleSetting{.{ .lang = null, .id = "shared", .project = true, .max_matches = 2 }};
    const input = try flood(arena.allocator(), "shared", 5);
    const out = try caps.apply(arena.allocator(), input, &settings, 0);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    for (out) |d| try std.testing.expectEqual(false, d.capped);
}

test "caps: a language setting does not cap a project diagnostic with the same rule ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const settings = [_]rule.RuleSetting{.{ .lang = .ts, .id = "shared", .max_matches = 2 }};
    const input = try flood(arena.allocator(), "shared", 5);
    for (input) |*d| d.rule_scope = .project;
    const out = try caps.apply(arena.allocator(), input, &settings, 0);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    for (out) |d| try std.testing.expectEqual(false, d.capped);
}

test "caps: language and project diagnostics with the same rule ID group independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = [_]diagnostic.Diagnostic{
        at("shared", 0),
        at("shared", 1),
        at("shared", 2),
        at("shared", 3),
    };
    input[1].rule_scope = .project;
    input[3].rule_scope = .project;

    const out = try caps.apply(arena.allocator(), &input, &.{}, 3);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    for (out, 0..) |d, line| {
        try std.testing.expectEqual(@as(u32, @intCast(line)), d.range.start.line);
        try std.testing.expectEqual(false, d.capped);
    }
}

test "caps: interleaved language and project floods keep order and cap independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = [_]diagnostic.Diagnostic{
        at("shared", 0),
        at("shared", 1),
        at("shared", 2),
        at("shared", 3),
        at("shared", 4),
        at("shared", 5),
        at("shared", 6),
        at("shared", 7),
    };
    input[1].rule_scope = .project;
    input[3].rule_scope = .project;
    input[5].rule_scope = .project;
    input[7].rule_scope = .project;

    const out = try caps.apply(arena.allocator(), &input, &.{}, 3);

    try std.testing.expectEqual(@as(usize, 8), out.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 0, 5, 1 }, &.{
        out[0].range.start.line,
        out[1].range.start.line,
        out[2].range.start.line,
        out[3].range.start.line,
        out[4].range.start.line,
        out[5].range.start.line,
        out[6].range.start.line,
        out[7].range.start.line,
    });
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, false, true }, &.{
        out[0].capped,
        out[1].capped,
        out[2].capped,
        out[3].capped,
        out[4].capped,
        out[5].capped,
        out[6].capped,
        out[7].capped,
    });
    try std.testing.expectEqual(diagnostic.RuleScope.language, out[5].rule_scope);
    try std.testing.expectEqual(diagnostic.RuleScope.project, out[7].rule_scope);
}

test "caps: diagnostics from different languages with the same rule ID group independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = [_]diagnostic.Diagnostic{
        at("shared", 0),
        at("shared", 1),
        at("shared", 2),
        at("shared", 3),
        at("shared", 4),
        at("shared", 5),
    };
    input[1].language = "go";
    input[3].language = "go";
    input[5].language = "go";

    const out = try caps.apply(arena.allocator(), &input, &.{}, 3);

    try std.testing.expectEqual(@as(usize, 6), out.len);
    for (out, 0..) |d, line| {
        try std.testing.expectEqual(@as(u32, @intCast(line)), d.range.start.line);
        try std.testing.expectEqual(false, d.capped);
    }
}

test "caps: two flooding rules cap independently and a quiet rule is untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input: std.ArrayList(diagnostic.Diagnostic) = .empty;
    for (0..6) |line| {
        try input.append(arena.allocator(), at("aaa-flood", @intCast(line)));
        try input.append(arena.allocator(), at("zzz-flood", @intCast(line)));
    }
    try input.append(arena.allocator(), at("quiet", 99));

    const out = try caps.apply(arena.allocator(), input.items, &.{}, 5);

    try std.testing.expectEqual(@as(usize, 9), out.len);
    var aaa: usize = 0;
    var zzz: usize = 0;
    var synthetic: usize = 0;
    for (out) |d| {
        if (d.capped) synthetic += 1;
        if (!d.capped and std.mem.eql(u8, d.rule_id, "aaa-flood")) aaa += 1;
        if (!d.capped and std.mem.eql(u8, d.rule_id, "zzz-flood")) zzz += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), aaa);
    try std.testing.expectEqual(@as(usize, 3), zzz);
    try std.testing.expectEqual(@as(usize, 2), synthetic);
    try std.testing.expectEqualStrings("aaa-flood", out[0].rule_id);
    try std.testing.expectEqualStrings("zzz-flood", out[1].rule_id);
    try std.testing.expectEqualStrings("aaa-flood", out[2].rule_id);
    try std.testing.expectEqualStrings("zzz-flood", out[3].rule_id);
    try std.testing.expectEqualStrings("aaa-flood", out[4].rule_id);
    try std.testing.expectEqual(true, out[5].capped);
    try std.testing.expectEqualStrings("aaa-flood", out[5].rule_id);
    try std.testing.expectEqualStrings("zzz-flood", out[6].rule_id);
    try std.testing.expectEqual(true, out[7].capped);
    try std.testing.expectEqualStrings("zzz-flood", out[7].rule_id);
    try std.testing.expectEqualStrings("quiet", out[8].rule_id);
}

fn onLine(rule_id: []const u8, message: []const u8, line: u32, column: u32) diagnostic.Diagnostic {
    return .{
        .rule_id = rule_id,
        .language = "ts",
        .message = message,
        .range = .{ .start = .{ .line = line, .column = column }, .end = .{ .line = line, .column = column + 3 } },
    };
}

test "collapse: three identical messages on one line pass through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input: []const diagnostic.Diagnostic = &.{
        onLine("no-magic", "magic number", 4, 0),
        onLine("no-magic", "magic number", 4, 10),
        onLine("no-magic", "magic number", 4, 20),
    };

    const out = try caps.collapse(arena.allocator(), input);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    for (out) |d| try std.testing.expectEqualStrings("magic number", d.message);
}

test "collapse: four identical messages on one line become one with a count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input: []const diagnostic.Diagnostic = &.{
        onLine("no-magic", "magic number", 4, 0),
        onLine("no-magic", "magic number", 4, 10),
        onLine("no-magic", "magic number", 4, 20),
        onLine("no-magic", "magic number", 4, 30),
    };

    const out = try caps.collapse(arena.allocator(), input);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("magic number; repeated 4 times on this line", out[0].message);
    try std.testing.expectEqual(@as(u32, 0), out[0].range.start.column);
}

test "collapse: a different line is never merged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input: []const diagnostic.Diagnostic = &.{
        onLine("no-magic", "magic number", 4, 0),
        onLine("no-magic", "magic number", 4, 10),
        onLine("no-magic", "magic number", 4, 20),
        onLine("no-magic", "magic number", 5, 0),
        onLine("no-magic", "magic number", 5, 10),
        onLine("no-magic", "magic number", 5, 20),
        onLine("no-magic", "magic number", 5, 30),
    };

    const out = try caps.collapse(arena.allocator(), input);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("magic number", out[2].message);
    try std.testing.expectEqualStrings("magic number; repeated 4 times on this line", out[3].message);
}

test "collapse: a different message or rule on the same line is never merged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input: []const diagnostic.Diagnostic = &.{
        onLine("no-magic", "magic number", 4, 0),
        onLine("no-magic", "magic number", 4, 10),
        onLine("no-magic", "other message", 4, 20),
        onLine("no-magic", "other message", 4, 30),
        onLine("other-rule", "magic number", 4, 40),
        onLine("other-rule", "magic number", 4, 50),
    };

    const out = try caps.collapse(arena.allocator(), input);

    try std.testing.expectEqual(@as(usize, 6), out.len);
}

test "collapse: an empty stream stays empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = try caps.collapse(arena.allocator(), &.{});

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

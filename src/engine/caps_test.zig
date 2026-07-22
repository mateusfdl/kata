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
    try std.testing.expectEqualStrings("quiet", out[8].rule_id);
}

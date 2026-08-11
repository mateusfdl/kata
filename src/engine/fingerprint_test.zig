const std = @import("std");

const lint = @import("engine");
const diagnostic = lint.diagnostic;
const fingerprint = lint.fingerprint;

fn finding(rule_id: []const u8, start_line: u32, start_column: u32, end_line: u32, end_column: u32) diagnostic.Diagnostic {
    return .{
        .rule_id = rule_id,
        .language = "ts",
        .message = "message",
        .range = .{
            .start = .{ .line = start_line, .column = start_column },
            .end = .{ .line = end_line, .column = end_column },
        },
    };
}

test "fingerprint: normalize collapses whitespace runs" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "value", .expected = "value" },
        .{ .input = "  value  ", .expected = "value" },
        .{ .input = "left\t\tright", .expected = "left right" },
        .{ .input = "left\n\nright", .expected = "left right" },
        .{ .input = " \tleft\r\n \tright\n", .expected = "left right" },
        .{ .input = " \t\r\n", .expected = "" },
        .{ .input = "", .expected = "" },
    };

    for (cases) |case| {
        const normalized = try fingerprint.normalize(std.testing.allocator, case.input);
        defer std.testing.allocator.free(normalized);

        try std.testing.expectEqualStrings(case.expected, normalized);
    }
}

test "fingerprint: normalize preserves non UTF-8 bytes" {
    const input = [_]u8{ 0xff, ' ', ' ', 0x80 };
    const expected = [_]u8{ 0xff, ' ', 0x80 };
    const normalized = try fingerprint.normalize(std.testing.allocator, &input);
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualSlices(u8, &expected, normalized);
}

test "fingerprint: normalizedSpans returns one normalized span per diagnostic in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", 0, 0, 0, 9),
        finding("rule", 1, 2, 1, 9),
    };
    const spans = try fingerprint.normalizedSpans(arena.allocator(), "one  \ttwo\nxxthree\n", &diagnostics);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("one two", spans[0]);
    try std.testing.expectEqualStrings("three", spans[1]);
}

test "fingerprint: normalizedSpans slices multi-line spans and clamps ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", 0, 2, 1, 5),
        finding("rule", 20, 20, 30, 30),
        finding("rule", 0, 5, 0, 2),
    };
    const spans = try fingerprint.normalizedSpans(arena.allocator(), "xxleft\nrightyy", &diagnostics);

    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("left right", spans[0]);
    try std.testing.expectEqualStrings("", spans[1]);
    try std.testing.expectEqualStrings("", spans[2]);
}

test "fingerprint: normalizedSpans clamps columns at the selected line end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", 0, 1, 0, 99),
        finding("rule", 1, 2, 1, 99),
    };
    const spans = try fingerprint.normalizedSpans(arena.allocator(), "ab\ncdef\nz", &diagnostics);

    try std.testing.expectEqualStrings("b", spans[0]);
    try std.testing.expectEqualStrings("ef", spans[1]);
}

test "fingerprint: assign distinguishes duplicate spans in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics = [_]diagnostic.Diagnostic{
        finding("rule", 0, 0, 0, 3),
        finding("rule", 0, 4, 0, 7),
    };
    try fingerprint.assign(arena.allocator(), "src/a.ts", "bad bad", &diagnostics);

    try std.testing.expectEqualStrings("7e4b9ca1bb52d1b0e7d481d72ee621e5e68f1f3cea974a84c7a15fe0fba47785", diagnostics[0].fingerprint);
    try std.testing.expectEqualStrings("4c6404b3742c24411d02a3565311983bcdc527124af8708ca67bd23736f9acb4", diagnostics[1].fingerprint);

    std.mem.reverse(diagnostic.Diagnostic, &diagnostics);
    try fingerprint.assign(arena.allocator(), "src/a.ts", "bad bad", &diagnostics);

    try std.testing.expectEqualStrings("4c6404b3742c24411d02a3565311983bcdc527124af8708ca67bd23736f9acb4", diagnostics[0].fingerprint);
    try std.testing.expectEqualStrings("7e4b9ca1bb52d1b0e7d481d72ee621e5e68f1f3cea974a84c7a15fe0fba47785", diagnostics[1].fingerprint);
}

test "fingerprint: assign is stable across unrelated edits and line movement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var before = [_]diagnostic.Diagnostic{finding("rule", 1, 0, 1, 3)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "one\nbad\n", &before);

    var after = [_]diagnostic.Diagnostic{finding("rule", 2, 0, 2, 3)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "changed\nelsewhere\nbad\n", &after);

    try std.testing.expectEqualStrings(before[0].fingerprint, after[0].fingerprint);
}

test "fingerprint: assign is stable across span whitespace formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var compact = [_]diagnostic.Diagnostic{finding("rule", 0, 0, 0, 8)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "left bad", &compact);

    var formatted = [_]diagnostic.Diagnostic{finding("rule", 0, 0, 1, 4)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "left \t\n bad", &formatted);

    try std.testing.expectEqualStrings(compact[0].fingerprint, formatted[0].fingerprint);
}

test "fingerprint: assign includes rule id and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var base = [_]diagnostic.Diagnostic{finding("rule", 0, 0, 0, 3)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "bad", &base);

    var other_rule = [_]diagnostic.Diagnostic{finding("other", 0, 0, 0, 3)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "bad", &other_rule);

    var other_path = [_]diagnostic.Diagnostic{finding("rule", 0, 0, 0, 3)};
    try fingerprint.assign(arena.allocator(), "src/b.ts", "bad", &other_path);

    try std.testing.expect(!std.mem.eql(u8, base[0].fingerprint, other_rule[0].fingerprint));
    try std.testing.expect(!std.mem.eql(u8, base[0].fingerprint, other_path[0].fingerprint));
}

test "fingerprint: assign slices multi-line spans and clamps ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var multi_line = [_]diagnostic.Diagnostic{finding("rule", 0, 2, 1, 5)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "xxleft\nrightyy", &multi_line);

    var equivalent = [_]diagnostic.Diagnostic{finding("rule", 0, 0, 0, 10)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "left right", &equivalent);

    try std.testing.expectEqualStrings(equivalent[0].fingerprint, multi_line[0].fingerprint);

    var past_end = [_]diagnostic.Diagnostic{finding("rule", 20, 20, 30, 30)};
    try fingerprint.assign(arena.allocator(), "src/a.ts", "short", &past_end);

    try std.testing.expectEqual(@as(usize, 64), past_end[0].fingerprint.len);
    for (past_end[0].fingerprint) |byte| try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
}

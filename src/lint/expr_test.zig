const std = @import("std");
const expr = @import("expr.zig");

const FakeResolver = struct {
    pub fn captureId(_: FakeResolver, name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "fn")) return 0;
        if (std.mem.eql(u8, name, "cls")) return 1;
        return null;
    }
};

const FakeMeasures = struct {
    complexity: u32 = 0,
    nesting: u32 = 0,
    length: u32 = 0,
    text: ?u32 = null,
    params: u32 = 0,
    args: u32 = 0,
    missing_capture: ?u32 = null,

    pub const Error = error{};

    pub fn measure(self: FakeMeasures, m: expr.Measure, capture_id: u32) Error!?u32 {
        if (self.missing_capture == capture_id) return null;
        return switch (m) {
            .complexity => self.complexity,
            .nesting => self.nesting,
            .length => self.length,
            .text => self.text,
            .params => self.params,
            .args => self.args,
        };
    }
};

fn evalWith(arena: std.mem.Allocator, source: []const u8, measures: FakeMeasures) !bool {
    const parsed = try expr.parse(arena, source, FakeResolver{});
    return expr.evaluate(parsed, measures);
}

test "expr: greater-than compares a measure against a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(> (complexity @fn) 15)", .{ .complexity = 16 }));
    try std.testing.expectEqual(false, try evalWith(a, "(> (complexity @fn) 15)", .{ .complexity = 15 }));
}

test "expr: all comparison operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(>= (nesting @fn) 3)", .{ .nesting = 3 }));
    try std.testing.expectEqual(false, try evalWith(a, "(>= (nesting @fn) 3)", .{ .nesting = 2 }));
    try std.testing.expectEqual(true, try evalWith(a, "(< (length @fn) 10)", .{ .length = 9 }));
    try std.testing.expectEqual(false, try evalWith(a, "(< (length @fn) 10)", .{ .length = 10 }));
    try std.testing.expectEqual(true, try evalWith(a, "(<= (length @fn) 10)", .{ .length = 10 }));
    try std.testing.expectEqual(false, try evalWith(a, "(<= (length @fn) 10)", .{ .length = 11 }));
    try std.testing.expectEqual(true, try evalWith(a, "(= (complexity @fn) 5)", .{ .complexity = 5 }));
    try std.testing.expectEqual(false, try evalWith(a, "(= (complexity @fn) 5)", .{ .complexity = 6 }));
    try std.testing.expectEqual(true, try evalWith(a, "(!= (complexity @fn) 5)", .{ .complexity = 6 }));
    try std.testing.expectEqual(false, try evalWith(a, "(!= (complexity @fn) 5)", .{ .complexity = 5 }));
}

test "expr: and requires every clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "(and (> (complexity @fn) 10) (> (nesting @fn) 2))";
    try std.testing.expectEqual(true, try evalWith(a, source, .{ .complexity = 11, .nesting = 3 }));
    try std.testing.expectEqual(false, try evalWith(a, source, .{ .complexity = 11, .nesting = 2 }));
    try std.testing.expectEqual(false, try evalWith(a, source, .{ .complexity = 10, .nesting = 3 }));
}

test "expr: or requires any clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "(or (> (complexity @fn) 10) (> (nesting @fn) 2))";
    try std.testing.expectEqual(true, try evalWith(a, source, .{ .complexity = 11, .nesting = 0 }));
    try std.testing.expectEqual(true, try evalWith(a, source, .{ .complexity = 0, .nesting = 3 }));
    try std.testing.expectEqual(false, try evalWith(a, source, .{ .complexity = 10, .nesting = 2 }));
}

test "expr: not inverts the inner expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(not (> (complexity @fn) 15))", .{ .complexity = 15 }));
    try std.testing.expectEqual(false, try evalWith(a, "(not (> (complexity @fn) 15))", .{ .complexity = 16 }));
}

test "expr: nested composition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "(and (or (> (complexity @fn) 10) (> (nesting @fn) 3)) (not (< (length @cls) 5)))";
    try std.testing.expectEqual(true, try evalWith(a, source, .{ .complexity = 11, .nesting = 0, .length = 5 }));
    try std.testing.expectEqual(false, try evalWith(a, source, .{ .complexity = 11, .nesting = 0, .length = 4 }));
    try std.testing.expectEqual(false, try evalWith(a, source, .{ .complexity = 10, .nesting = 3, .length = 5 }));
}

test "expr: missing capture in match fails the comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(false, try evalWith(a, "(> (complexity @fn) 0)", .{ .complexity = 5, .missing_capture = 0 }));
    try std.testing.expectEqual(true, try evalWith(a, "(not (> (complexity @fn) 0))", .{ .complexity = 5, .missing_capture = 0 }));
}

test "expr: numbers compare on both sides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(> 3 2)", .{}));
    try std.testing.expectEqual(false, try evalWith(a, "(> 2 3)", .{}));
}

test "expr: text measure compares parsed numeric text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(> (text @fn) 30000)", .{ .text = 60000 }));
    try std.testing.expectEqual(false, try evalWith(a, "(> (text @fn) 30000)", .{ .text = 30000 }));
    try std.testing.expectEqual(false, try evalWith(a, "(> (text @fn) 30000)", .{ .text = null }));
}

test "expr: params and args measures compare counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try evalWith(a, "(> (params @fn) 4)", .{ .params = 5 }));
    try std.testing.expectEqual(false, try evalWith(a, "(> (params @fn) 4)", .{ .params = 4 }));
    try std.testing.expectEqual(true, try evalWith(a, "(> (args @fn) 3)", .{ .args = 4 }));
    try std.testing.expectEqual(false, try evalWith(a, "(> (args @fn) 3)", .{ .args = 3 }));
}

test "expr: parse errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { source: []const u8, expected: expr.ParseError }{
        .{ .source = "", .expected = error.MalformedExpression },
        .{ .source = "(> (complexity @fn) 15", .expected = error.MalformedExpression },
        .{ .source = "(> (complexity @fn) 15))", .expected = error.MalformedExpression },
        .{ .source = "(> (complexity @fn) 15) 1", .expected = error.MalformedExpression },
        .{ .source = "(> (complexity @fn))", .expected = error.MalformedExpression },
        .{ .source = "(> (complexity fn) 15)", .expected = error.MalformedExpression },
        .{ .source = "(and)", .expected = error.MalformedExpression },
        .{ .source = "(between (complexity @fn) 1 5)", .expected = error.UnknownOperator },
        .{ .source = "(> (lines @fn) 4)", .expected = error.UnknownMeasure },
        .{ .source = "(> (complexity @nope) 15)", .expected = error.UnknownCapture },
        .{ .source = "(> (complexity @fn) lots)", .expected = error.InvalidNumber },
        .{ .source = "(> (complexity @fn) -1)", .expected = error.InvalidNumber },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, expr.parse(a, case.source, FakeResolver{}));
    }
}

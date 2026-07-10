const std = @import("std");
const nk = @import("node_kinds");

const ast = @import("ast.zig");
const kind_map = @import("core").kind_map;
const language = @import("core").language;
const lower = @import("lower.zig");
const parser = @import("parser.zig");
const query = @import("core").query;

fn tsId(comptime name: []const u8) u16 {
    return @intFromEnum(@field(nk.ts_family.Kind, name));
}

fn tsRemap(arena: std.mem.Allocator) []const u16 {
    const kinds = kind_map.build(.ts, language.grammar(.ts), arena) catch unreachable;
    return kinds.kind_remap;
}

fn matchPattern(arena: std.mem.Allocator, src: []const u8) ast.NodePattern {
    var diag: parser.Diagnostic = .{};
    var p = parser.Parser.init(arena, src, &diag) catch unreachable;
    const file = p.parseFile() catch unreachable;
    return file.rules[0].match.?.node;
}

fn lowerSrc(arena: std.mem.Allocator, src: []const u8) lower.Error!lower.Lowered {
    const pattern = matchPattern(arena, src);
    var lowerer = lower.Lowerer.init(arena, language.grammar(.ts), tsRemap(arena));
    const lowered = try lowerer.lowerPattern(pattern);
    return lowerer.finish(lowered);
}

test "lower: field pattern assigns capture ids by occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try lowerSrc(arena.allocator(),
        \\rule r {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    name: identifier @n
        \\  }
        \\  emit @match { message "m" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), result.capture_names.len);
    try std.testing.expectEqual(@as(?query.CaptureId, 0), result.idForName("match"));
    try std.testing.expectEqual(@as(?query.CaptureId, 1), result.idForName("n"));

    try std.testing.expectEqual(tsId("variable_declarator"), result.pattern.kind.symbol);
    try std.testing.expectEqual(@as(?query.CaptureId, 0), result.pattern.capture);

    const field = result.pattern.fields[0];
    try std.testing.expectEqualStrings("name", field.relation.field);
    try std.testing.expectEqual(tsId("identifier"), field.pattern.kind.symbol);
    try std.testing.expectEqual(@as(?query.CaptureId, 1), field.pattern.capture);
}

test "lower: alternation lowers each branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try lowerSrc(arena.allocator(),
        \\rule r {
        \\  lang ts
        \\  match [function_declaration, arrow_function] @match
        \\  emit @match { message "m" }
        \\}
    );

    const branches = result.pattern.kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqual(tsId("function_declaration"), branches[0].kind.symbol);
    try std.testing.expectEqual(tsId("arrow_function"), branches[1].kind.symbol);
    try std.testing.expectEqual(@as(?query.CaptureId, 0), result.pattern.capture);
}

test "lower: repeated capture name reuses its id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try lowerSrc(arena.allocator(),
        \\rule r {
        \\  lang ts
        \\  match binary_expression @match {
        \\    left: identifier @side
        \\    right: identifier @side
        \\  }
        \\  emit @match { message "m" }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), result.capture_names.len);
    try std.testing.expectEqual(result.pattern.fields[0].pattern.capture, result.pattern.fields[1].pattern.capture);
}

test "lower: unknown node kind fails with the offending name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pattern = matchPattern(arena.allocator(),
        \\rule r {
        \\  lang ts
        \\  match faketype @match
        \\  emit @match { message "m" }
        \\}
    );
    var lowerer = lower.Lowerer.init(arena.allocator(), language.grammar(.ts), tsRemap(arena.allocator()));

    try std.testing.expectError(error.UnknownNodeKind, lowerer.lowerPattern(pattern));
    try std.testing.expectEqualStrings("faketype", lowerer.detail);
}

test "lower: unknown field fails with the offending name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pattern = matchPattern(arena.allocator(),
        \\rule r {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    fakefield: identifier @n
        \\  }
        \\  emit @match { message "m" }
        \\}
    );
    var lowerer = lower.Lowerer.init(arena.allocator(), language.grammar(.ts), tsRemap(arena.allocator()));

    try std.testing.expectError(error.UnknownField, lowerer.lowerPattern(pattern));
    try std.testing.expectEqualStrings("fakefield", lowerer.detail);
}

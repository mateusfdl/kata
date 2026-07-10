const std = @import("std");

const query = @import("../core.zig").query;
const test_tree = @import("test_tree.zig");

const Pattern = query.Pattern;

test "query: symbol capture matches every occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const a = b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
    try std.testing.expectEqualStrings("b", matches[1].get(0).?.text(src).?);
}

test "query: field relation binds the field child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const a = 1;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("variable_declarator") },
        .fields = &.{.{
            .relation = .{ .field = "name" },
            .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
}

test "query: unanchored child yields one match per satisfying child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "class C { foo() {} bar() {} }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("class_body") },
        .fields = &.{.{
            .relation = .child,
            .pattern = .{ .kind = .{ .symbol = t.sym("method_definition") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expect(std.mem.startsWith(u8, matches[0].get(0).?.text(src).?, "foo"));
    try std.testing.expect(std.mem.startsWith(u8, matches[1].get(0).?.text(src).?, "bar"));
}

test "query: alternation matches any branch kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "function f() {} const g = () => {};";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = t.sym("function_declaration") } },
            .{ .kind = .{ .symbol = t.sym("arrow_function") } },
        } },
        .capture = 0,
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "query: anonymous token under a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "const c = a && b;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("binary_expression") },
        .capture = 0,
        .fields = &.{.{
            .relation = .{ .field = "operator" },
            .pattern = .{ .kind = .{ .anonymous = t.tok("&&") } },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a && b", matches[0].get(0).?.text(src).?);
}

test "query: absent field excludes nodes that have it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "let x; let y = 1;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const pattern: Pattern = .{
        .kind = .{ .symbol = t.sym("variable_declarator") },
        .capture = 0,
        .absent_fields = &.{"value"},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, t.root());

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("x", matches[0].get(0).?.text(src).?);
}

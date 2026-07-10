const std = @import("std");
const ts = @import("tree_sitter");

const kind_map = @import("kind_map.zig");
const language = @import("language.zig");
const node = @import("node.zig");
const query = @import("query.zig");

const Node = node.Node;
const Pattern = query.Pattern;

fn parse(source: []const u8) *ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language.grammar(.ts)) catch unreachable;
    return parser.parseString(source, null).?;
}

fn tsKinds() node.Kinds {
    return kind_map.build(.ts, language.grammar(.ts), std.testing.allocator) catch unreachable;
}

fn sym(kinds: node.Kinds, name: []const u8) u16 {
    return kinds.kind_remap[language.grammar(.ts).idForNodeKind(name, true)];
}

fn tok(kinds: node.Kinds, name: []const u8) u16 {
    return kinds.kind_remap[language.grammar(.ts).idForNodeKind(name, false)];
}

test "query: symbol capture matches every occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "const a = b;";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{ .kind = .{ .symbol = sym(kinds, "identifier") }, .capture = 0 };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
    try std.testing.expectEqualStrings("b", matches[1].get(0).?.text(src).?);
}

test "query: field relation binds the field child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "const a = 1;";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{
        .kind = .{ .symbol = sym(kinds, "variable_declarator") },
        .fields = &.{.{
            .relation = .{ .field = "name" },
            .pattern = .{ .kind = .{ .symbol = sym(kinds, "identifier") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a", matches[0].get(0).?.text(src).?);
}

test "query: unanchored child yields one match per satisfying child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "class C { foo() {} bar() {} }";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{
        .kind = .{ .symbol = sym(kinds, "class_body") },
        .fields = &.{.{
            .relation = .child,
            .pattern = .{ .kind = .{ .symbol = sym(kinds, "method_definition") }, .capture = 0 },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expect(std.mem.startsWith(u8, matches[0].get(0).?.text(src).?, "foo"));
    try std.testing.expect(std.mem.startsWith(u8, matches[1].get(0).?.text(src).?, "bar"));
}

test "query: alternation matches any branch kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "function f() {} const g = () => {};";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{
        .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = sym(kinds, "function_declaration") } },
            .{ .kind = .{ .symbol = sym(kinds, "arrow_function") } },
        } },
        .capture = 0,
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "query: anonymous token under a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "const c = a && b;";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{
        .kind = .{ .symbol = sym(kinds, "binary_expression") },
        .capture = 0,
        .fields = &.{.{
            .relation = .{ .field = "operator" },
            .pattern = .{ .kind = .{ .anonymous = tok(kinds, "&&") } },
        }},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("a && b", matches[0].get(0).?.text(src).?);
}

test "query: absent field excludes nodes that have it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);

    const src = "let x; let y = 1;";
    const tree = parse(src);
    defer tree.destroy();

    const pattern: Pattern = .{
        .kind = .{ .symbol = sym(kinds, "variable_declarator") },
        .capture = 0,
        .absent_fields = &.{"value"},
    };
    const matches = try query.run(arena.allocator(), &pattern, 1, Node.from(tree.rootNode(), &kinds));

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("x", matches[0].get(0).?.text(src).?);
}

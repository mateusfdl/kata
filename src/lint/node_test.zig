const std = @import("std");
const ts = @import("tree_sitter");

const kind_map = @import("kind_map.zig");
const language = @import("language.zig");
const node = @import("node.zig");

const Node = node.Node;

fn parse(source: []const u8) *ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language.grammar(.ts)) catch unreachable;
    return parser.parseString(source, null).?;
}

fn tsKinds() node.Kinds {
    return kind_map.build(.ts, language.grammar(.ts), std.testing.allocator) catch unreachable;
}

test "node: kind, byte span, and text of the root" {
    const src = "const x = 42;";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    try std.testing.expectEqualStrings("program", root.kind());
    try std.testing.expectEqual(@as(u32, 0), root.startByte());
    try std.testing.expectEqual(@as(u32, src.len), root.endByte());
    try std.testing.expectEqualStrings(src, root.text(src).?);
}

test "node: field child, points, parent identity" {
    const src = "const x = 42;\n";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    const decl = root.namedChild(0).?;
    const declarator = decl.namedChild(0).?;

    const name = declarator.childByFieldName("name").?;
    try std.testing.expectEqualStrings("identifier", name.kind());
    try std.testing.expectEqualStrings("x", name.text(src).?);
    try std.testing.expectEqual(@as(u32, 0), name.startPoint().row);
    try std.testing.expectEqual(@as(u32, 6), name.startPoint().column);

    const value = declarator.childByFieldName("value").?;
    try std.testing.expectEqualStrings("42", value.text(src).?);

    try std.testing.expect(name.parent().?.eql(declarator));
    try std.testing.expect(!name.eql(value));
}

test "node: named-sibling navigation and count" {
    const src = "f(a, b, c);";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    const call = root.namedChild(0).?.namedChild(0).?;
    const args = call.childByFieldName("arguments").?;

    try std.testing.expectEqual(@as(u32, 3), args.namedChildCount());

    const last = args.namedChild(2).?;
    try std.testing.expectEqualStrings("c", last.text(src).?);
    try std.testing.expectEqualStrings("b", last.prevNamedSibling().?.text(src).?);
}

test "node: comment inside params is extra" {
    const src = "function f(/* c */ a) {}";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    const func = root.namedChild(0).?;
    const params = func.childByFieldName("parameters").?;

    var saw_extra = false;
    var i: u32 = 0;
    while (i < params.namedChildCount()) : (i += 1) {
        if (params.namedChild(i).?.isExtra()) saw_extra = true;
    }
    try std.testing.expect(saw_extra);
}

test "node: named symbol vs anonymous token" {
    const src = "x;";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    const stmt = root.namedChild(0).?;

    const identifier = stmt.child(0).?;
    try std.testing.expectEqualStrings("identifier", identifier.kind());
    try std.testing.expect(identifier.isNamed());

    const semicolon = stmt.child(1).?;
    try std.testing.expectEqualStrings(";", semicolon.kind());
    try std.testing.expect(!semicolon.isNamed());
}

test "node: symbol is the grammar id for the kind" {
    const src = "const x = 42;";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    const grammar = language.grammar(.ts);

    try std.testing.expectEqual(grammar.idForNodeKind("program", true), root.symbol());

    const name = root.namedChild(0).?.namedChild(0).?.childByFieldName("name").?;
    try std.testing.expectEqual(grammar.idForNodeKind("identifier", true), name.symbol());
    try std.testing.expect(root.symbol() != name.symbol());
}

test "node: text is null when span exceeds the given source" {
    const src = "const x = 42;";
    const tree = parse(src);
    defer tree.destroy();

    var kinds = tsKinds();
    defer std.testing.allocator.free(kinds.kind_remap);
    const root = Node.from(tree.rootNode(), &kinds);
    try std.testing.expectEqual(@as(?[]const u8, null), root.text("short"));
}

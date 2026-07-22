const std = @import("std");
const nk = @import("node_kinds");

const test_tree = @import("test_tree.zig");

test "node: kind, byte span, and text of the root" {
    const src = "const x = 42;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
    try std.testing.expectEqualStrings("program", root.kind());
    try std.testing.expectEqual(@as(u32, 0), root.startByte());
    try std.testing.expectEqual(@as(u32, src.len), root.endByte());
    try std.testing.expectEqualStrings(src, root.text(src).?);
}

test "node: field child, points, parent identity" {
    const src = "const x = 42;\n";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
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

test "node: field child by id resolves the same node as by name" {
    const src = "const x = 42;\n";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const declarator = t.root().namedChild(0).?.namedChild(0).?;
    const name_field: u16 = @intFromEnum(nk.ts_family.Field.name);

    const by_id = declarator.childByFieldId(name_field).?;
    const by_name = declarator.childByFieldName("name").?;
    try std.testing.expect(by_id.eql(by_name));
    try std.testing.expectEqualStrings("x", by_id.text(src).?);

    const missing_field: u16 = @intFromEnum(nk.ts_family.Field.condition);
    try std.testing.expectEqual(@as(?@TypeOf(by_id), null), declarator.childByFieldId(missing_field));
}

test "node: named-sibling navigation and count" {
    const src = "f(a, b, c);";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
    const call = root.namedChild(0).?.namedChild(0).?;
    const args = call.childByFieldName("arguments").?;

    try std.testing.expectEqual(@as(u32, 3), args.namedChildCount());

    const last = args.namedChild(2).?;
    try std.testing.expectEqualStrings("c", last.text(src).?);
    try std.testing.expectEqualStrings("b", last.prevNamedSibling().?.text(src).?);
}

test "node: comment inside params is extra" {
    const src = "function f(/* c */ a) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
    const func = root.namedChild(0).?;
    const params = func.childByFieldName("parameters").?;

    var saw_extra = false;
    var i: u32 = 0;
    while (i < params.namedChildCount()) : (i += 1) {
        if (params.namedChild(i).?.isExtra()) saw_extra = true;
    }
    try std.testing.expect(saw_extra);
}

test "node: named symbol and anonymous token kinds" {
    const src = "x;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
    const stmt = root.namedChild(0).?;

    const identifier = stmt.child(0).?;
    try std.testing.expectEqualStrings("identifier", identifier.kind());

    const semicolon = stmt.child(1).?;
    try std.testing.expectEqualStrings(";", semicolon.kind());
}

test "node: text is null when span exceeds the given source" {
    const src = "const x = 42;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), t.root().text("short"));
}

test "node: preorder visits each subtree node once" {
    const src = "const x = call(1);";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var nodes = t.root().preorder();
    var count: usize = 0;
    while (nodes.next()) |_| count += 1;

    try std.testing.expectEqual(t.ast.nodes.len, count);
}

test "node: child iterators visit direct children in source order" {
    const src = "f(a, b);";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const call = t.root().namedChild(0).?.namedChild(0).?;
    const args = call.childByFieldName("arguments").?;

    var all = args.children();
    try std.testing.expectEqualStrings("(", all.next().?.text(src).?);
    try std.testing.expectEqualStrings("a", all.next().?.text(src).?);
    try std.testing.expectEqualStrings(",", all.next().?.text(src).?);
    try std.testing.expectEqualStrings("b", all.next().?.text(src).?);
    try std.testing.expectEqualStrings(")", all.next().?.text(src).?);
    try std.testing.expectEqual(@as(?@TypeOf(args), null), all.next());

    var named = args.namedChildren();
    try std.testing.expectEqualStrings("a", named.next().?.text(src).?);
    try std.testing.expectEqualStrings("b", named.next().?.text(src).?);
    try std.testing.expectEqual(@as(?@TypeOf(args), null), named.next());
}

const std = @import("std");

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

test "node: named symbol vs anonymous token" {
    const src = "x;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const root = t.root();
    const stmt = root.namedChild(0).?;

    const identifier = stmt.child(0).?;
    try std.testing.expectEqualStrings("identifier", identifier.kind());
    try std.testing.expect(identifier.isNamed());

    const semicolon = stmt.child(1).?;
    try std.testing.expectEqualStrings(";", semicolon.kind());
    try std.testing.expect(!semicolon.isNamed());
}

test "node: text is null when span exceeds the given source" {
    const src = "const x = 42;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), t.root().text("short"));
}

const std = @import("std");
const ts = @import("tree_sitter");
const nk = @import("node_kinds");

const ast = @import("ast.zig");
const convert = @import("convert.zig");
const kind_map = @import("kind_map.zig");
const language = @import("language.zig");
const node = @import("node.zig");

fn parse(grammar: *const ts.Language, source: []const u8) *ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(grammar) catch unreachable;
    return parser.parseString(source, null).?;
}

fn fieldRemap(lang: language.Name, grammar: *const ts.Language) []u16 {
    return switch (lang) {
        .ts, .tsx => nk.ts_family.buildFieldRemap(grammar, std.testing.allocator) catch unreachable,
        .go => nk.go.buildFieldRemap(grammar, std.testing.allocator) catch unreachable,
    };
}

const Walker = struct {
    tree: ast.Ast,
    grammar: *const ts.Language,
    kinds: *const node.Kinds,
    field_remap: []const u16,
    next: ast.NodeIndex = 0,

    fn visit(self: *Walker, tsn: ts.Node, expected_parent: ast.NodeIndex, expected_field: u16) !void {
        const index = self.next;
        self.next += 1;
        const stored = self.tree.nodes[index];

        try std.testing.expectEqual(node.Node.from(tsn, self.kinds).kindId(), stored.kind);
        try std.testing.expectEqual(expected_field, stored.field_id);
        try std.testing.expectEqual(tsn.startByte(), stored.start_byte);
        try std.testing.expectEqual(tsn.endByte(), stored.end_byte);
        try std.testing.expectEqual(tsn.isNamed(), stored.flags.named);
        try std.testing.expectEqual(tsn.isExtra(), stored.flags.extra);
        try expectPoint(tsn.startPoint(), self.tree.pointAt(stored.start_byte));
        try expectPoint(tsn.endPoint(), self.tree.pointAt(stored.end_byte));
        try std.testing.expectEqual(expected_parent, stored.parent);

        var c: u32 = 0;
        while (c < tsn.childCount()) : (c += 1) {
            const child = tsn.child(c).?;
            const fname = tsn.fieldNameForChild(c);
            const field = if (fname) |name| self.field_remap[self.grammar.fieldIdForName(name)] else 0;
            try self.visit(child, index, field);
        }

        try std.testing.expectEqual(self.next, stored.subtree_end);
    }
};

fn expectPoint(expected: ts.Point, actual: ast.Point) !void {
    try std.testing.expectEqual(expected.row, actual.row);
    try std.testing.expectEqual(expected.column, actual.column);
}

fn expectClone(lang: language.Name, source: []const u8) !void {
    const grammar = language.grammar(lang);
    const tree = parse(grammar, source);
    defer tree.destroy();

    var kinds = try kind_map.build(lang, grammar, std.testing.allocator);
    defer std.testing.allocator.free(kinds.kind_remap);

    const remap = fieldRemap(lang, grammar);
    defer std.testing.allocator.free(remap);

    var cloned = try convert.build(lang, grammar, tree.rootNode(), source, std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    var walker: Walker = .{ .tree = cloned, .grammar = grammar, .kinds = &kinds, .field_remap = remap };
    try walker.visit(tree.rootNode(), ast.no_parent, 0);

    try std.testing.expectEqual(tree.rootNode().descendantCount(), cloned.nodes.len);
    try std.testing.expectEqual(cloned.nodes.len, walker.next);
}

test "convert: clones a ts tree node-for-node" {
    try expectClone(.ts,
        \\const x = "héllo";
        \\function f(a, b) { return a && b ? a : b; }
        \\
    );
}

test "convert: clones a tsx tree node-for-node" {
    try expectClone(.tsx,
        \\const el = <div className={y}>{z}</div>;
        \\function g<T>(a: T): T { return a; }
        \\
    );
}

test "convert: clones a go tree node-for-node" {
    try expectClone(.go,
        \\package main
        \\
        \\func f(a, b int) int {
        \\    if a && b > 0 {
        \\        return a
        \\    }
        \\    return b
        \\}
        \\
    );
}

test "convert: node ending at EOF without a trailing newline" {
    try expectClone(.ts, "const y = 1;");
}

test "convert: syntax error funnels ERROR to kata kind 0 without panic" {
    const grammar = language.grammar(.ts);
    const source = "class {";
    const tree = parse(grammar, source);
    defer tree.destroy();

    var cloned = try convert.build(.ts, grammar, tree.rootNode(), source, std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    var saw_error = false;
    for (cloned.nodes) |n| {
        if (n.kind == 0) saw_error = true;
    }
    try std.testing.expect(saw_error);
}

test "convert: empty source is a single childless root" {
    const grammar = language.grammar(.ts);
    const tree = parse(grammar, "");
    defer tree.destroy();

    var cloned = try convert.build(.ts, grammar, tree.rootNode(), "", std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cloned.nodes.len);
    try std.testing.expectEqual(ast.no_parent, cloned.nodes[0].parent);
    try std.testing.expectEqual(@as(ast.NodeIndex, 1), cloned.nodes[0].subtree_end);
}

const std = @import("std");
const ts = @import("tree_sitter");
const node_kinds = @import("node_kinds");

const ast = @import("ast.zig");
const language = @import("language.zig");

/// Clone a finished tree-sitter CST rooted at `root` into a flat kata `Ast`. The
/// walk is an iterative pre-order DFS (depth-safe on adversarial nesting), and it
/// stores kata kind/field ids resolved through the same per-grammar remaps the
/// matcher reads, so a converted node's kind equals `Node.kindId()` on the same
/// ts node by construction. Anonymous tokens keep their field ids, which the
/// bool-op metric refinement depends on.
pub fn build(
    lang: language.Name,
    grammar: *const ts.Language,
    root: ts.Node,
    source: []const u8,
    gpa: std.mem.Allocator,
) !ast.Ast {
    const kind_remap = try buildKindRemap(lang, grammar, gpa);
    defer gpa.free(kind_remap);
    const field_remap = try buildFieldRemap(lang, grammar, gpa);
    defer gpa.free(field_remap);

    var nodes: std.ArrayList(ast.StoredNode) = .empty;
    errdefer nodes.deinit(gpa);

    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(gpa);

    var cursor = root.walk();
    defer cursor.destroy();

    outer: while (true) {
        const n = cursor.node();
        const index: ast.NodeIndex = @intCast(nodes.items.len);
        const parent = if (stack.items.len == 0) ast.no_parent else stack.getLast();
        try nodes.append(gpa, .{
            .kind = remap(kind_remap, n.kindId()),
            .field_id = remap(field_remap, cursor.fieldId()),
            .flags = .{ .named = n.isNamed(), .extra = n.isExtra() },
            .start_byte = n.startByte(),
            .end_byte = n.endByte(),
            .subtree_end = undefined,
            .parent = parent,
        });

        if (cursor.gotoFirstChild()) {
            try stack.append(gpa, index);
            continue;
        }

        nodes.items[index].subtree_end = @intCast(nodes.items.len);
        while (!cursor.gotoNextSibling()) {
            if (!cursor.gotoParent()) break :outer;
            const done = stack.pop().?;
            nodes.items[done].subtree_end = @intCast(nodes.items.len);
        }
    }

    const line_starts = try buildLineStarts(source, gpa);
    errdefer gpa.free(line_starts);

    return .{
        .lang = lang,
        .nodes = try nodes.toOwnedSlice(gpa),
        .line_starts = line_starts,
    };
}

/// tree-sitter's ERROR symbol is `0xFFFF`, past every grammar's table, so it
/// funnels to kata id 0 (`.unknown`/`.none`) instead of indexing out of bounds.
fn remap(table: []const u16, id: u16) u16 {
    return if (id < table.len) table[id] else 0;
}

fn buildKindRemap(lang: language.Name, grammar: *const ts.Language, gpa: std.mem.Allocator) ![]u16 {
    return switch (lang) {
        .ts, .tsx => node_kinds.ts_family.buildKindRemap(grammar, gpa),
        .go => node_kinds.go.buildKindRemap(grammar, gpa),
    };
}

fn buildFieldRemap(lang: language.Name, grammar: *const ts.Language, gpa: std.mem.Allocator) ![]u16 {
    return switch (lang) {
        .ts, .tsx => node_kinds.ts_family.buildFieldRemap(grammar, gpa),
        .go => node_kinds.go.buildFieldRemap(grammar, gpa),
    };
}

fn buildLineStarts(source: []const u8, gpa: std.mem.Allocator) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);

    try starts.append(gpa, 0);
    for (source, 0..) |c, i| {
        if (c == '\n') try starts.append(gpa, @intCast(i + 1));
    }

    return starts.toOwnedSlice(gpa);
}

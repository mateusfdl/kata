const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const family_mod = @import("family/family.zig");
const line_index = @import("line_index.zig");
const stack = @import("shared").stack;

/// clone a finished tree-sitter CST rooted at `root` into a flat kata `Ast`.
/// The  walk is an iterative pre-order DFS (depth-safe hopefully), and it
/// stores kind/field ids resolved through the caller's per-grammar remaps,
/// so a converted node's kind equals what
/// the matcher expects by construction.
/// Anonymous tokens keep their field ids, which the bool-op metric refinement depends on.
pub fn build(
    fam: family_mod.Family,
    kind_remap: []const u16,
    field_remap: []const u16,
    root: ts.Node,
    source: []const u8,
    gpa: std.mem.Allocator,
) !ast.Ast {
    const descendant_count: usize = @intCast(root.descendantCount());
    std.debug.assert(descendant_count > 0);
    std.debug.assert(descendant_count <= std.math.maxInt(ast.NodeIndex));

    var nodes = try std.ArrayList(ast.StoredNode).initCapacity(gpa, descendant_count);
    errdefer nodes.deinit(gpa);

    var parents = try stack.ValueStackType(ast.NodeIndex).init(gpa, descendant_count);
    defer parents.deinit();
    std.debug.assert(parents.capacity() == descendant_count);

    var cursor = root.walk();
    defer cursor.destroy();

    outer: while (true) {
        const n = cursor.node();
        std.debug.assert(nodes.items.len < descendant_count);
        std.debug.assert(n.startByte() <= n.endByte());
        std.debug.assert(n.endByte() <= source.len);
        const index: ast.NodeIndex = @intCast(nodes.items.len);
        const parent = if (parents.empty()) ast.no_parent else parents.peek();
        std.debug.assert((index == 0) == (parent == ast.no_parent));
        if (parent != ast.no_parent) {
            std.debug.assert(parent < index);
            const parent_node = nodes.items[parent];
            std.debug.assert(parent_node.start_byte <= n.startByte());
            std.debug.assert(n.endByte() <= parent_node.end_byte);
        }
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
            parents.push(index);

            continue;
        }

        nodes.items[index].subtree_end = @intCast(nodes.items.len);
        while (!cursor.gotoNextSibling()) {
            if (!cursor.gotoParent()) break :outer;
            const done = parents.pop();

            std.debug.assert(done < nodes.items.len);
            nodes.items[done].subtree_end = @intCast(nodes.items.len);
        }
    }

    std.debug.assert(parents.empty());
    std.debug.assert(nodes.items.len == descendant_count);
    std.debug.assert(nodes.items[0].subtree_end == descendant_count);
    for (nodes.items, 0..) |node, node_index| {
        std.debug.assert(node_index < node.subtree_end);
        std.debug.assert(node.subtree_end <= descendant_count);
        if (node.parent != ast.no_parent) {
            std.debug.assert(node.parent < node_index);
            std.debug.assert(node.subtree_end <= nodes.items[node.parent].subtree_end);
        }
    }

    var index = try line_index.LineIndex.init(gpa, source);
    errdefer index.deinit(gpa);

    return .{
        .family = fam,
        .nodes = try nodes.toOwnedSlice(gpa),
        .line_starts = index.release(),
    };
}

/// tree-sitter's ERROR symbol is `0xFFFF`, past every grammar's table, so it
/// funnels to kata id 0 .unknown/.none instead of getting hit back by outbounding it huh
fn remap(table: []const u16, id: u16) u16 {
    return if (id < table.len) table[id] else 0;
}

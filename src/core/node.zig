const std = @import("std");
const nk = @import("node_kinds");

const ast = @import("ast.zig");
const language = @import("language.zig");

pub const Point = ast.Point;

/// A handle over a single node in kata's flat `Ast`. Every consumer (matcher,
/// metrics, facts) talks to this surface rather than the store directly, so the
/// node representation can change without touching them.
pub const Node = struct {
    tree: *const ast.Ast,
    index: ast.NodeIndex,

    pub fn fromKata(tree: *const ast.Ast, index: ast.NodeIndex) Node {
        return .{ .tree = tree, .index = index };
    }

    fn stored(self: Node) ast.StoredNode {
        return self.tree.nodes[self.index];
    }

    pub fn kind(self: Node) []const u8 {
        return kindName(self.tree.lang, self.stored().kind);
    }

    pub fn kindId(self: Node) u16 {
        return self.stored().kind;
    }

    pub fn startByte(self: Node) u32 {
        return self.stored().start_byte;
    }

    pub fn endByte(self: Node) u32 {
        return self.stored().end_byte;
    }

    pub fn startPoint(self: Node) Point {
        return self.tree.pointAt(self.stored().start_byte);
    }

    pub fn endPoint(self: Node) Point {
        return self.tree.pointAt(self.stored().end_byte);
    }

    pub fn parent(self: Node) ?Node {
        const p = self.stored().parent;
        return if (p == ast.no_parent) null else fromKata(self.tree, p);
    }

    pub fn child(self: Node, index: u32) ?Node {
        return self.childAt(index, false);
    }

    pub fn childCount(self: Node) u32 {
        return self.countChildren(false);
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        return self.childAt(index, true);
    }

    pub fn namedChildCount(self: Node) u32 {
        return self.countChildren(true);
    }

    pub fn childByFieldName(self: Node, name: []const u8) ?Node {
        const field_id = fieldEnumId(self.tree.lang, name);
        if (field_id == 0) return null;
        const nodes = self.tree.nodes;
        const end = self.stored().subtree_end;
        var j = self.index + 1;
        while (j < end) : (j = nodes[j].subtree_end) {
            if (nodes[j].field_id == field_id) return fromKata(self.tree, j);
        }
        return null;
    }

    pub fn fieldNameForChild(self: Node, index: u32) ?[]const u8 {
        const c = self.childAt(index, false) orelse return null;
        return fieldName(self.tree.lang, c.stored().field_id);
    }

    pub fn prevNamedSibling(self: Node) ?Node {
        const nodes = self.tree.nodes;
        const p = self.stored().parent;
        if (p == ast.no_parent) return null;
        const end = nodes[p].subtree_end;
        var prev: ?ast.NodeIndex = null;
        var j = p + 1;
        while (j < end and j != self.index) : (j = nodes[j].subtree_end) {
            if (nodes[j].flags.named) prev = j;
        }
        return if (prev) |pi| fromKata(self.tree, pi) else null;
    }

    pub fn isNamed(self: Node) bool {
        return self.stored().flags.named;
    }

    pub fn isExtra(self: Node) bool {
        return self.stored().flags.extra;
    }

    pub fn eql(self: Node, other: Node) bool {
        return self.tree == other.tree and self.index == other.index;
    }

    /// Source text this node spans, or null when the node reaches past the end
    /// of `source` (a node from a different parse).
    pub fn text(self: Node, source: []const u8) ?[]const u8 {
        const end = self.endByte();
        if (end > source.len) return null;
        return source[self.startByte()..end];
    }

    fn countChildren(self: Node, named_only: bool) u32 {
        const nodes = self.tree.nodes;
        const end = self.stored().subtree_end;
        var count: u32 = 0;
        var j = self.index + 1;
        while (j < end) : (j = nodes[j].subtree_end) {
            if (!named_only or nodes[j].flags.named) count += 1;
        }
        return count;
    }

    fn childAt(self: Node, index: u32, named_only: bool) ?Node {
        const nodes = self.tree.nodes;
        const end = self.stored().subtree_end;
        var seen: u32 = 0;
        var j = self.index + 1;
        while (j < end) : (j = nodes[j].subtree_end) {
            if (!named_only or nodes[j].flags.named) {
                if (seen == index) return fromKata(self.tree, j);
                seen += 1;
            }
        }
        return null;
    }
};

fn kindName(lang: language.Name, id: u16) []const u8 {
    return switch (lang) {
        .ts, .tsx => nk.ts_family.name(id),
        .go => nk.go.name(id),
    };
}

fn fieldEnumId(lang: language.Name, name: []const u8) u16 {
    return switch (lang) {
        .ts, .tsx => enumId(nk.ts_family.Field, name),
        .go => enumId(nk.go.Field, name),
    };
}

fn enumId(comptime Field: type, name: []const u8) u16 {
    return if (std.meta.stringToEnum(Field, name)) |f| @intFromEnum(f) else 0;
}

fn fieldName(lang: language.Name, id: u16) ?[]const u8 {
    if (id == 0) return null;
    return switch (lang) {
        .ts, .tsx => @tagName(@as(nk.ts_family.Field, @enumFromInt(id))),
        .go => @tagName(@as(nk.go.Field, @enumFromInt(id))),
    };
}

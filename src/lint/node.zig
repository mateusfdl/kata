const std = @import("std");
const ts = @import("tree_sitter");

pub const Point = struct {
    row: u32,
    column: u32,
};

/// Per-grammar `ts symbol id -> kata kind id` table, built once at startup and
/// shared by every node of that grammar. It is the single source of truth for
/// kata kind ids: the same table lowers pattern kind names to ids and answers
/// `kindId()`, so a pattern id and a node id agree by construction.
pub const Kinds = struct {
    kind_remap: []const u16,
};

/// A handle over a single syntax node. Today it wraps a tree-sitter node; the
/// engine talks to this surface instead of `ts.Node` so the backing tree can be
/// swapped for kata's own AST without touching the matcher, metrics, or facts.
pub const Node = struct {
    inner: ts.Node,
    kinds: *const Kinds,

    pub fn from(inner: ts.Node, kinds: *const Kinds) Node {
        return .{ .inner = inner, .kinds = kinds };
    }

    pub fn kind(self: Node) []const u8 {
        return self.inner.kind();
    }

    pub fn symbol(self: Node) u16 {
        return self.inner.kindId();
    }

    pub fn kindId(self: Node) u16 {
        const sym = self.inner.kindId();
        const remap = self.kinds.kind_remap;
        return if (sym < remap.len) remap[sym] else 0;
    }

    pub fn startByte(self: Node) u32 {
        return self.inner.startByte();
    }

    pub fn endByte(self: Node) u32 {
        return self.inner.endByte();
    }

    pub fn startPoint(self: Node) Point {
        const p = self.inner.startPoint();
        return .{ .row = p.row, .column = p.column };
    }

    pub fn endPoint(self: Node) Point {
        const p = self.inner.endPoint();
        return .{ .row = p.row, .column = p.column };
    }

    pub fn parent(self: Node) ?Node {
        return self.wrap(self.inner.parent());
    }

    pub fn child(self: Node, index: u32) ?Node {
        return self.wrap(self.inner.child(index));
    }

    pub fn childCount(self: Node) u32 {
        return self.inner.childCount();
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        return self.wrap(self.inner.namedChild(index));
    }

    pub fn namedChildCount(self: Node) u32 {
        return self.inner.namedChildCount();
    }

    pub fn childByFieldName(self: Node, name: []const u8) ?Node {
        return self.wrap(self.inner.childByFieldName(name));
    }

    pub fn fieldNameForChild(self: Node, index: u32) ?[]const u8 {
        return self.inner.fieldNameForChild(index);
    }

    pub fn prevNamedSibling(self: Node) ?Node {
        return self.wrap(self.inner.prevNamedSibling());
    }

    pub fn isNamed(self: Node) bool {
        return self.inner.isNamed();
    }

    pub fn isExtra(self: Node) bool {
        return self.inner.isExtra();
    }

    pub fn eql(self: Node, other: Node) bool {
        return self.inner.eql(other.inner);
    }

    /// Source text this node spans, or null when the node reaches past the end
    /// of `source` (a node from a different parse).
    pub fn text(self: Node, source: []const u8) ?[]const u8 {
        const end = self.endByte();
        if (end > source.len) return null;
        return source[self.startByte()..end];
    }

    fn wrap(self: Node, maybe: ?ts.Node) ?Node {
        return if (maybe) |n| .{ .inner = n, .kinds = self.kinds } else null;
    }
};

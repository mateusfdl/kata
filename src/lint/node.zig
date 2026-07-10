const std = @import("std");
const ts = @import("tree_sitter");
const nk = @import("node_kinds");

const ast = @import("ast.zig");
const language = @import("language.zig");

pub const Point = ast.Point;

/// Per-grammar `ts symbol id -> kata kind id` table, built once at startup and
/// shared by every ts-backed node of that grammar. It is the single source of
/// truth for kata kind ids on the ts arm: the same table lowers pattern kind
/// names to ids and answers `kindId()`, so a pattern id and a node id agree by
/// construction. The kata arm stores kata ids directly and needs no remap.
pub const Kinds = struct {
    kind_remap: []const u16,
};

const TsArm = struct {
    inner: ts.Node,
    kinds: *const Kinds,
};

pub const KataRef = struct {
    tree: *const ast.Ast,
    index: ast.NodeIndex,
};

/// A handle over a single syntax node. It carries one of two backends: a
/// tree-sitter node, or a reference into kata's own flat `Ast`. Every consumer
/// (matcher, metrics, facts) talks to this surface, so the backing tree can be
/// swapped without touching them. Once the kata backend is proven equal to
/// tree-sitter, the ts arm is deleted and `Node` collapses to a `KataRef`.
pub const Node = struct {
    backend: union(enum) {
        ts: TsArm,
        kata: KataRef,
    },

    pub fn from(inner: ts.Node, kinds: *const Kinds) Node {
        return .{ .backend = .{ .ts = .{ .inner = inner, .kinds = kinds } } };
    }

    pub fn fromKata(tree: *const ast.Ast, index: ast.NodeIndex) Node {
        return .{ .backend = .{ .kata = .{ .tree = tree, .index = index } } };
    }

    pub fn kind(self: Node) []const u8 {
        return switch (self.backend) {
            .ts => |t| t.inner.kind(),
            .kata => |k| kindName(k.tree.lang, k.tree.nodes[k.index].kind),
        };
    }

    pub fn symbol(self: Node) u16 {
        return switch (self.backend) {
            .ts => |t| t.inner.kindId(),
            .kata => unreachable,
        };
    }

    pub fn kindId(self: Node) u16 {
        return switch (self.backend) {
            .ts => |t| {
                const sym = t.inner.kindId();
                const remap = t.kinds.kind_remap;
                return if (sym < remap.len) remap[sym] else 0;
            },
            .kata => |k| k.tree.nodes[k.index].kind,
        };
    }

    pub fn startByte(self: Node) u32 {
        return switch (self.backend) {
            .ts => |t| t.inner.startByte(),
            .kata => |k| k.tree.nodes[k.index].start_byte,
        };
    }

    pub fn endByte(self: Node) u32 {
        return switch (self.backend) {
            .ts => |t| t.inner.endByte(),
            .kata => |k| k.tree.nodes[k.index].end_byte,
        };
    }

    pub fn startPoint(self: Node) Point {
        return switch (self.backend) {
            .ts => |t| .{ .row = t.inner.startPoint().row, .column = t.inner.startPoint().column },
            .kata => |k| k.tree.pointAt(k.tree.nodes[k.index].start_byte),
        };
    }

    pub fn endPoint(self: Node) Point {
        return switch (self.backend) {
            .ts => |t| .{ .row = t.inner.endPoint().row, .column = t.inner.endPoint().column },
            .kata => |k| k.tree.pointAt(k.tree.nodes[k.index].end_byte),
        };
    }

    pub fn parent(self: Node) ?Node {
        return switch (self.backend) {
            .ts => |t| tsWrap(t.kinds, t.inner.parent()),
            .kata => |k| {
                const p = k.tree.nodes[k.index].parent;
                return if (p == ast.no_parent) null else fromKata(k.tree, p);
            },
        };
    }

    pub fn child(self: Node, index: u32) ?Node {
        return switch (self.backend) {
            .ts => |t| tsWrap(t.kinds, t.inner.child(index)),
            .kata => |k| kataChildAt(k, index, false),
        };
    }

    pub fn childCount(self: Node) u32 {
        return switch (self.backend) {
            .ts => |t| t.inner.childCount(),
            .kata => |k| kataChildCount(k, false),
        };
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        return switch (self.backend) {
            .ts => |t| tsWrap(t.kinds, t.inner.namedChild(index)),
            .kata => |k| kataChildAt(k, index, true),
        };
    }

    pub fn namedChildCount(self: Node) u32 {
        return switch (self.backend) {
            .ts => |t| t.inner.namedChildCount(),
            .kata => |k| kataChildCount(k, true),
        };
    }

    pub fn childByFieldName(self: Node, name: []const u8) ?Node {
        return switch (self.backend) {
            .ts => |t| tsWrap(t.kinds, t.inner.childByFieldName(name)),
            .kata => |k| kataChildByField(k, kataFieldId(k.tree.lang, name)),
        };
    }

    pub fn fieldNameForChild(self: Node, index: u32) ?[]const u8 {
        return switch (self.backend) {
            .ts => |t| t.inner.fieldNameForChild(index),
            .kata => |k| {
                const c = kataChildAt(k, index, false) orelse return null;
                return fieldName(k.tree.lang, k.tree.nodes[c.backend.kata.index].field_id);
            },
        };
    }

    pub fn prevNamedSibling(self: Node) ?Node {
        return switch (self.backend) {
            .ts => |t| tsWrap(t.kinds, t.inner.prevNamedSibling()),
            .kata => |k| kataPrevNamedSibling(k),
        };
    }

    pub fn isNamed(self: Node) bool {
        return switch (self.backend) {
            .ts => |t| t.inner.isNamed(),
            .kata => |k| k.tree.nodes[k.index].flags.named,
        };
    }

    pub fn isExtra(self: Node) bool {
        return switch (self.backend) {
            .ts => |t| t.inner.isExtra(),
            .kata => |k| k.tree.nodes[k.index].flags.extra,
        };
    }

    pub fn eql(self: Node, other: Node) bool {
        return switch (self.backend) {
            .ts => |t| switch (other.backend) {
                .ts => |o| t.inner.eql(o.inner),
                .kata => false,
            },
            .kata => |k| switch (other.backend) {
                .kata => |o| k.tree == o.tree and k.index == o.index,
                .ts => false,
            },
        };
    }

    /// Source text this node spans, or null when the node reaches past the end
    /// of `source` (a node from a different parse).
    pub fn text(self: Node, source: []const u8) ?[]const u8 {
        const end = self.endByte();
        if (end > source.len) return null;
        return source[self.startByte()..end];
    }
};

fn tsWrap(kinds: *const Kinds, maybe: ?ts.Node) ?Node {
    return if (maybe) |n| Node.from(n, kinds) else null;
}

fn kindName(lang: language.Name, id: u16) []const u8 {
    return switch (lang) {
        .ts, .tsx => nk.ts_family.name(id),
        .go => nk.go.name(id),
    };
}

fn kataFieldId(lang: language.Name, name: []const u8) u16 {
    return switch (lang) {
        .ts, .tsx => fieldEnumId(nk.ts_family.Field, name),
        .go => fieldEnumId(nk.go.Field, name),
    };
}

fn fieldEnumId(comptime Field: type, name: []const u8) u16 {
    return if (std.meta.stringToEnum(Field, name)) |f| @intFromEnum(f) else 0;
}

fn fieldName(lang: language.Name, id: u16) ?[]const u8 {
    if (id == 0) return null;
    return switch (lang) {
        .ts, .tsx => @tagName(@as(nk.ts_family.Field, @enumFromInt(id))),
        .go => @tagName(@as(nk.go.Field, @enumFromInt(id))),
    };
}

fn kataChildCount(k: KataRef, named_only: bool) u32 {
    const nodes = k.tree.nodes;
    const end = nodes[k.index].subtree_end;
    var count: u32 = 0;
    var j = k.index + 1;
    while (j < end) : (j = nodes[j].subtree_end) {
        if (!named_only or nodes[j].flags.named) count += 1;
    }
    return count;
}

fn kataChildAt(k: KataRef, index: u32, named_only: bool) ?Node {
    const nodes = k.tree.nodes;
    const end = nodes[k.index].subtree_end;
    var seen: u32 = 0;
    var j = k.index + 1;
    while (j < end) : (j = nodes[j].subtree_end) {
        if (!named_only or nodes[j].flags.named) {
            if (seen == index) return Node.fromKata(k.tree, j);
            seen += 1;
        }
    }
    return null;
}

fn kataChildByField(k: KataRef, field_id: u16) ?Node {
    if (field_id == 0) return null;
    const nodes = k.tree.nodes;
    const end = nodes[k.index].subtree_end;
    var j = k.index + 1;
    while (j < end) : (j = nodes[j].subtree_end) {
        if (nodes[j].field_id == field_id) return Node.fromKata(k.tree, j);
    }
    return null;
}

fn kataPrevNamedSibling(k: KataRef) ?Node {
    const nodes = k.tree.nodes;
    const p = nodes[k.index].parent;
    if (p == ast.no_parent) return null;
    const end = nodes[p].subtree_end;
    var prev: ?ast.NodeIndex = null;
    var j = p + 1;
    while (j < end and j != k.index) : (j = nodes[j].subtree_end) {
        if (nodes[j].flags.named) prev = j;
    }
    return if (prev) |pi| Node.fromKata(k.tree, pi) else null;
}

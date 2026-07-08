const std = @import("std");

const node = @import("node.zig");

const Node = node.Node;
const Error = std.mem.Allocator.Error;

pub const CaptureId = u16;

/// The kind gate for a pattern node. `symbol` matches a named grammar node by
/// kind name; `anonymous` matches an anonymous token; `alternation` matches when
/// any branch matches, binding this pattern's capture to the node either way.
pub const Kind = union(enum) {
    symbol: []const u8,
    anonymous: []const u8,
    alternation: []const Pattern,
};

/// How a field pattern relates to its parent. `field` is a tree-sitter
/// field-tagged child; `child` is any immediate named child (unanchored);
/// `children` is zero-or-more immediate named children.
pub const Relation = union(enum) {
    field: []const u8,
    child,
    children,
};

pub const Field = struct {
    relation: Relation,
    pattern: Pattern,
};

pub const Pattern = struct {
    kind: Kind,
    capture: ?CaptureId = null,
    fields: []const Field = &.{},
    absent_fields: []const []const u8 = &.{},
};

/// A single successful match: capture id -> bound node. Slots left null were not
/// bound (e.g. an alternation branch that did not fire).
pub const Match = struct {
    nodes: []const ?Node,

    pub fn get(self: Match, id: CaptureId) ?Node {
        if (id >= self.nodes.len) return null;
        return self.nodes[id];
    }
};

/// Run `pattern` over the subtree at `root`, returning one Match per satisfying
/// assignment in pre-order. `capture_count` sizes each Match. Matching a node
/// with an unanchored `child` relation that has several satisfying children
/// yields one Match per child, reproducing tree-sitter query multiplicity.
pub fn run(
    arena: std.mem.Allocator,
    pattern: *const Pattern,
    capture_count: usize,
    root: Node,
) Error![]Match {
    var collector: Collector = .{ .arena = arena };
    const scratch = try arena.alloc(?Node, capture_count);
    @memset(scratch, null);
    try walk(pattern, root, scratch, &collector);
    return collector.matches.toOwnedSlice(arena);
}

const Collector = struct {
    arena: std.mem.Allocator,
    matches: std.ArrayList(Match) = .empty,

    fn emit(self: *Collector, bindings: []const ?Node) Error!void {
        const owned = try self.arena.dupe(?Node, bindings);
        try self.matches.append(self.arena, .{ .nodes = owned });
    }
};

/// Continuation for the enumerating recursion: `emit` yields a full match;
/// `fields` resumes the parent's remaining field patterns. Frames live on the
/// stack for the duration of the synchronous descent.
const Cont = union(enum) {
    emit,
    fields: struct {
        fields: []const Field,
        index: usize,
        parent: Node,
        next: *const Cont,
    },
};

fn walk(pattern: *const Pattern, n: Node, scratch: []?Node, collector: *Collector) Error!void {
    const emit: Cont = .emit;
    try matchNode(pattern, n, scratch, &emit, collector);

    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        try walk(pattern, n.child(i).?, scratch, collector);
    }
}

fn matchNode(
    pattern: *const Pattern,
    n: Node,
    bindings: []?Node,
    cont: *const Cont,
    collector: *Collector,
) Error!void {
    if (pattern.kind == .alternation) {
        var saved: ?Node = undefined;
        if (pattern.capture) |c| {
            saved = bindings[c];
            bindings[c] = n;
        }
        defer if (pattern.capture) |c| {
            bindings[c] = saved;
        };
        for (pattern.kind.alternation) |*branch| {
            try matchNode(branch, n, bindings, cont, collector);
        }
        return;
    }

    if (!kindMatches(pattern, n)) return;

    var saved: ?Node = undefined;
    if (pattern.capture) |c| {
        saved = bindings[c];
        bindings[c] = n;
    }
    defer if (pattern.capture) |c| {
        bindings[c] = saved;
    };

    for (pattern.absent_fields) |field_name| {
        if (n.childByFieldName(field_name) != null) return;
    }

    try matchFields(pattern.fields, 0, n, bindings, cont, collector);
}

fn matchFields(
    fields: []const Field,
    index: usize,
    parent: Node,
    bindings: []?Node,
    next: *const Cont,
    collector: *Collector,
) Error!void {
    if (index == fields.len) return invoke(next, bindings, collector);

    const field = &fields[index];
    const cont: Cont = .{ .fields = .{
        .fields = fields,
        .index = index + 1,
        .parent = parent,
        .next = next,
    } };

    switch (field.relation) {
        .field => |name| {
            const child = parent.childByFieldName(name) orelse return;
            try matchNode(&field.pattern, child, bindings, &cont, collector);
        },
        .child => {
            var k: u32 = 0;
            while (k < parent.namedChildCount()) : (k += 1) {
                try matchNode(&field.pattern, parent.namedChild(k).?, bindings, &cont, collector);
            }
        },
        .children => try matchChildren(&field.pattern, parent, bindings, &cont, collector),
    }
}

/// Zero-or-more immediate named children. With a single-node capture slot this
/// binds the first matching child (or none) and resumes once, since `*` is
/// always satisfiable. No shipped rule exercises this relation.
fn matchChildren(
    pattern: *const Pattern,
    parent: Node,
    bindings: []?Node,
    next: *const Cont,
    collector: *Collector,
) Error!void {
    var k: u32 = 0;
    while (k < parent.namedChildCount()) : (k += 1) {
        const child = parent.namedChild(k).?;
        if (!kindMatches(pattern, child)) continue;

        var saved: ?Node = undefined;
        if (pattern.capture) |c| {
            saved = bindings[c];
            bindings[c] = child;
        }
        defer if (pattern.capture) |c| {
            bindings[c] = saved;
        };
        return invoke(next, bindings, collector);
    }

    return invoke(next, bindings, collector);
}

fn invoke(cont: *const Cont, bindings: []?Node, collector: *Collector) Error!void {
    switch (cont.*) {
        .emit => try collector.emit(bindings),
        .fields => |f| try matchFields(f.fields, f.index, f.parent, bindings, f.next, collector),
    }
}

fn kindMatches(pattern: *const Pattern, n: Node) bool {
    return switch (pattern.kind) {
        .symbol => |k| n.isNamed() and std.mem.eql(u8, n.kind(), k),
        .anonymous => |k| !n.isNamed() and std.mem.eql(u8, n.kind(), k),
        .alternation => |branches| {
            for (branches) |*branch| {
                if (kindMatches(branch, n)) return true;
            }
            return false;
        },
    };
}

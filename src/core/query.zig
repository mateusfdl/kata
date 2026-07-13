const std = @import("std");

const node = @import("node.zig");

const Node = node.Node;
const Error = std.mem.Allocator.Error;

pub const CaptureId = u16;

/// The kind gate for a pattern node. `symbol` and `anonymous` both match a node
/// by its kata kind id (u16); the two variants differ only so lowering can
/// resolve a named kind against `idForNodeKind(name, true)` versus an anonymous
/// token against `(name, false)`. Named and anonymous kata ids occupy disjoint
/// ranges, so at match time both are a plain integer compare. `symbols` matches
/// a node whose kata kind id is in the (sorted) set, used for a supertype
/// expanded to its concrete member kinds. `alternation` matches when any branch
/// matches, binding this pattern's capture either way.
pub const Kind = union(enum) {
    symbol: u16,
    anonymous: u16,
    symbols: []const u16,
    alternation: []const Pattern,
};

/// How a field pattern relates to its parent. `field` is a tree-sitter
/// field-tagged child, keyed by its kata Field id (resolved at lower time);
/// `child` is any immediate named child (unanchored); `children` is zero-or-more
/// immediate named children.
pub const Relation = union(enum) {
    field: u16,
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
    absent_fields: []const u16 = &.{},
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
/// yields one Match per child, reproducing tree-sitter query multiplicity. A
/// capture id shared by several pattern nodes keeps its first binding.
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
        min_child: u32,
        next: *const Cont,
        fired: ?*bool = null,
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
            if (saved == null) bindings[c] = n;
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
        if (saved == null) bindings[c] = n;
    }
    defer if (pattern.capture) |c| {
        bindings[c] = saved;
    };

    for (pattern.absent_fields) |field_id| {
        if (n.childByFieldId(field_id) != null) return;
    }

    try matchFields(pattern.fields, 0, n, 0, bindings, cont, collector);
}

/// `min_child` is the lowest named-child index the next unanchored child may
/// bind, so a sequence of `child` patterns matches distinct siblings in tree
/// order (tree-sitter's unanchored-but-ordered semantics). `field` relations are
/// keyed by name and leave the sibling cursor untouched.
fn matchFields(
    fields: []const Field,
    index: usize,
    parent: Node,
    min_child: u32,
    bindings: []?Node,
    next: *const Cont,
    collector: *Collector,
) Error!void {
    if (index == fields.len) return invoke(next, bindings, collector);

    const field = &fields[index];

    switch (field.relation) {
        .field => |field_id| {
            const child = parent.childByFieldId(field_id) orelse return;
            const cont = fieldsCont(fields, index, parent, min_child, next);
            try matchNode(&field.pattern, child, bindings, &cont, collector);
        },
        .child => {
            var k: u32 = min_child;
            while (k < parent.namedChildCount()) : (k += 1) {
                const cont = fieldsCont(fields, index, parent, k + 1, next);
                try matchNode(&field.pattern, parent.namedChild(k).?, bindings, &cont, collector);
            }
        },
        .children => try matchChildren(&field.pattern, parent, index, fields, min_child, bindings, next, collector),
    }
}

fn fieldsCont(fields: []const Field, index: usize, parent: Node, min_child: u32, next: *const Cont) Cont {
    return .{ .fields = .{
        .fields = fields,
        .index = index + 1,
        .parent = parent,
        .min_child = min_child,
        .next = next,
    } };
}

/// Zero-or-more immediate named children. With a single-node capture slot this
/// binds the first child at or after `min_child` that satisfies the full child
/// pattern (or none) and resumes once, since `*` is always satisfiable.
fn matchChildren(
    pattern: *const Pattern,
    parent: Node,
    index: usize,
    fields: []const Field,
    min_child: u32,
    bindings: []?Node,
    next: *const Cont,
    collector: *Collector,
) Error!void {
    var fired = false;
    var k: u32 = min_child;
    while (k < parent.namedChildCount()) : (k += 1) {
        var cont = fieldsCont(fields, index, parent, k + 1, next);
        cont.fields.fired = &fired;
        try matchNode(pattern, parent.namedChild(k).?, bindings, &cont, collector);
        if (fired) return;
    }

    return matchFields(fields, index + 1, parent, min_child, bindings, next, collector);
}

fn invoke(cont: *const Cont, bindings: []?Node, collector: *Collector) Error!void {
    switch (cont.*) {
        .emit => try collector.emit(bindings),
        .fields => |f| {
            if (f.fired) |flag| flag.* = true;
            try matchFields(f.fields, f.index, f.parent, f.min_child, bindings, f.next, collector);
        },
    }
}

fn orderU16(key: u16, item: u16) std.math.Order {
    return std.math.order(key, item);
}

fn kindMatches(pattern: *const Pattern, n: Node) bool {
    return switch (pattern.kind) {
        .symbol => |id| n.kindId() == id,
        .anonymous => |id| n.kindId() == id,
        .symbols => |ids| std.sort.binarySearch(u16, ids, n.kindId(), orderU16) != null,
        .alternation => |branches| {
            for (branches) |*branch| {
                if (kindMatches(branch, n)) return true;
            }
            return false;
        },
    };
}

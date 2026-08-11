const std = @import("std");

const match_workspace = @import("match_workspace.zig");
const node = @import("node.zig");

const MatchWorkspace = match_workspace.MatchWorkspace;
const Node = node.Node;
const Error = std.mem.Allocator.Error;

pub const CaptureId = u16;
pub const ScanControl = enum {
    continue_scan,
    stop,
};

/// the kind gate for a pattern node. `symbol` and `anonymous` both match a node
/// by its kata kind id (u16); the two variants differ only so lowering can
/// resolve a named kind against `idfornodekind(name, true)` versus an anonymous
/// token against `(name, false)`. named and anonymous kata ids occupy disjoint
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

/// how a field pattern relates to its parent. `field` is a tree-sitter
/// field-tagged child, keyed by its field id (resolved at lower time);
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

/// a single successful match: capture id -> bound node. slots left null were not
/// bound (e.g. an alternation branch that did not fire).
pub const Match = struct {
    nodes: []const ?Node,

    pub fn get(self: Match, id: CaptureId) ?Node {
        if (id >= self.nodes.len) return null;
        return self.nodes[id];
    }
};

const Collector = struct {
    arena: std.mem.Allocator,
    matches: std.ArrayList(Match) = .empty,

    fn emit(self: *Collector, bindings: []const ?Node) Error!ScanControl {
        const owned = try self.arena.dupe(?Node, bindings);
        try self.matches.append(self.arena, .{ .nodes = owned });
        return .continue_scan;
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

/// run `pattern` over the subtree at `root`, returning one match per satisfying
/// assignment in pre-order. `capture_count` sizes each match. matching a node
/// with an unanchored `child` relation that has several satisfying children
/// yields one match per child, reproducing tree-sitter query multiplicity. a
/// capture id shared by several pattern nodes keeps its first binding.
pub fn run(
    arena: std.mem.Allocator,
    pattern: *const Pattern,
    capture_count: usize,
    root: Node,
) Error![]Match {
    var collector: Collector = .{ .arena = arena };
    try stream(arena, pattern, capture_count, root, &collector);
    return collector.matches.toOwnedSlice(arena);
}

/// run `pattern` anchored at `n` only, returning the matches rooted there in
/// enumeration order. descendants of `n` are not offered as anchors.
pub fn runAt(
    arena: std.mem.Allocator,
    pattern: *const Pattern,
    capture_count: usize,
    n: Node,
) Error![]Match {
    var collector: Collector = .{ .arena = arena };
    try streamAt(arena, pattern, capture_count, n, &collector);
    return collector.matches.toOwnedSlice(arena);
}

/// run `pattern` like `run`, but hand each match to `sink.emit` as it is found
/// instead of materializing a slice. the match handed to `emit` views the live
/// binding scratch and is only valid during that call. `scratch` only backs the
/// binding slots and is released before returning.
pub fn stream(
    scratch: std.mem.Allocator,
    pattern: *const Pattern,
    capture_count: usize,
    root: Node,
    sink: anytype,
) Error!void {
    var workspace = MatchWorkspace.init(scratch);
    defer workspace.deinit();
    try streamWithWorkspace(&workspace, pattern, capture_count, root, sink);
}

pub fn streamAt(
    scratch: std.mem.Allocator,
    pattern: *const Pattern,
    capture_count: usize,
    n: Node,
    sink: anytype,
) Error!void {
    var workspace = MatchWorkspace.init(scratch);
    defer workspace.deinit();
    try streamAtWithWorkspace(&workspace, pattern, capture_count, n, sink);
}

pub fn streamWithWorkspace(
    workspace: *MatchWorkspace,
    pattern: *const Pattern,
    capture_count: usize,
    root: Node,
    sink: anytype,
) Error!void {
    // The sink borrows active bindings and may not start a scan with this same
    // workspace. A reentrant scan would reset bindings still in use by emit.
    try workspace.reset(capture_count);
    _ = try walk(pattern, root, workspace.active(), sink);
}

pub fn streamAtWithWorkspace(
    workspace: *MatchWorkspace,
    pattern: *const Pattern,
    capture_count: usize,
    n: Node,
    sink: anytype,
) Error!void {
    // Anchored dispatch shares the same borrowing and reentrancy contract as
    // streamWithWorkspace, but offers only n as a root candidate.
    try workspace.reset(capture_count);
    const emit: Cont = .emit;
    _ = try matchNode(pattern, n, workspace.active(), &emit, sink);
}

fn walk(pattern: *const Pattern, n: Node, scratch: []?Node, collector: anytype) Error!ScanControl {
    var nodes = n.preorder();
    while (nodes.next()) |candidate| {
        const emit: Cont = .emit;
        const control = try matchNode(pattern, candidate, scratch, &emit, collector);
        if (control == .stop) return .stop;
    }
    return .continue_scan;
}

fn matchNode(
    pattern: *const Pattern,
    n: Node,
    bindings: []?Node,
    cont: *const Cont,
    collector: anytype,
) Error!ScanControl {
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
            const control = try matchNode(branch, n, bindings, cont, collector);
            if (control == .stop) return .stop;
        }

        return .continue_scan;
    }

    if (!kindMatches(pattern, n)) return .continue_scan;

    var saved: ?Node = undefined;
    if (pattern.capture) |c| {
        saved = bindings[c];

        if (saved == null) bindings[c] = n;
    }
    defer if (pattern.capture) |c| {
        bindings[c] = saved;
    };

    for (pattern.absent_fields) |field_id| {
        if (n.childByFieldId(field_id) != null) return .continue_scan;
    }

    return matchFields(pattern.fields, 0, n, 0, bindings, cont, collector);
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
    collector: anytype,
) Error!ScanControl {
    if (index == fields.len) return invoke(next, bindings, collector);

    const field = &fields[index];

    switch (field.relation) {
        .field => |field_id| {
            const child = parent.childByFieldId(field_id) orelse return .continue_scan;
            const cont = fieldsCont(fields, index, parent, min_child, next);
            return matchNode(&field.pattern, child, bindings, &cont, collector);
        },
        .child => {
            var children = parent.namedChildren();
            var k: u32 = min_child;
            var skipped: u32 = 0;
            while (skipped < min_child) : (skipped += 1) _ = children.next() orelse return .continue_scan;
            while (children.next()) |child| : (k += 1) {
                const cont = fieldsCont(fields, index, parent, k + 1, next);
                const control = try matchNode(&field.pattern, child, bindings, &cont, collector);
                if (control == .stop) return .stop;
            }
            return .continue_scan;
        },
        .children => return matchChildren(&field.pattern, parent, index, fields, min_child, bindings, next, collector),
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
    collector: anytype,
) Error!ScanControl {
    var fired = false;
    var children = parent.namedChildren();
    var k: u32 = min_child;
    var skipped: u32 = 0;
    while (skipped < min_child) : (skipped += 1) _ = children.next() orelse return matchFields(fields, index + 1, parent, min_child, bindings, next, collector);
    while (children.next()) |child| : (k += 1) {
        var cont = fieldsCont(fields, index, parent, k + 1, next);
        cont.fields.fired = &fired;
        const control = try matchNode(pattern, child, bindings, &cont, collector);
        if (control == .stop) return .stop;
        if (fired) return .continue_scan;
    }

    return matchFields(fields, index + 1, parent, min_child, bindings, next, collector);
}

fn invoke(cont: *const Cont, bindings: []?Node, collector: anytype) Error!ScanControl {
    return switch (cont.*) {
        .emit => collector.emit(bindings),
        .fields => |f| {
            if (f.fired) |flag| flag.* = true;

            return matchFields(f.fields, f.index, f.parent, f.min_child, bindings, f.next, collector);
        },
    };
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

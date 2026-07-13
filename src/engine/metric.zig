const std = @import("std");

const family_mod = @import("family/family.zig");
const Node = @import("node.zig").Node;

pub const MetricKind = enum {
    function,
    branch,
    ternary,
    loop,
    case,
    switch_stmt,
    catch_clause,
    bool_op,
};

pub fn classify(table: []const ?MetricKind, node: Node) ?MetricKind {
    const id = node.kindId();
    if (id >= table.len) return null;
    const mk = table[id] orelse return null;
    if (mk == .bool_op) {
        const op = node.childByFieldName("operator") orelse return null;
        if (!isLogicalOperator(op.kind())) return null;
    }
    return mk;
}

fn isLogicalOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "&&") or
        std.mem.eql(u8, op, "||") or
        std.mem.eql(u8, op, "??");
}

fn isComplexityPoint(kind: MetricKind) bool {
    return switch (kind) {
        .branch, .ternary, .loop, .case, .catch_clause, .bool_op => true,
        .function, .switch_stmt => false,
    };
}

fn isNestingConstruct(kind: MetricKind) bool {
    return switch (kind) {
        .branch, .loop, .switch_stmt, .catch_clause => true,
        .function, .ternary, .case, .bool_op => false,
    };
}

pub const Compiled = struct {
    table: []const ?MetricKind,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        allocator.free(self.table);
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    fam: family_mod.Family,
) std.mem.Allocator.Error!Compiled {
    return .{ .table = try family_mod.of(fam).buildMetricTable(allocator) };
}

const Span = struct {
    kind: MetricKind,
    start: u32,
    end: u32,
};

/// Spans sorted parent-before-child plus, for every span, the index of the
/// innermost function span that strictly contains it (null when the span sits
/// outside any captured function). The owner and depth passes rely on the
/// parent-before-child order.
const Analysis = struct {
    spans: []const Span,
    owners: []const ?usize,

    fn deinit(self: Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.owners);
        allocator.free(self.spans);
    }
};

fn analyze(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    root: Node,
) std.mem.Allocator.Error!Analysis {
    var list: std.ArrayList(Span) = .empty;
    errdefer list.deinit(allocator);
    try collectSpans(allocator, compiled, root, &list);
    std.mem.sort(Span, list.items, {}, spanLessThan);

    const spans = try list.toOwnedSlice(allocator);
    errdefer allocator.free(spans);
    const owners = try computeOwners(allocator, spans);

    return .{ .spans = spans, .owners = owners };
}

/// Single stack pass: spans arrive parent-before-child, so the functions still
/// open at a span's start are exactly the functions containing it.
fn computeOwners(allocator: std.mem.Allocator, spans: []const Span) std.mem.Allocator.Error![]?usize {
    const owners = try allocator.alloc(?usize, spans.len);
    errdefer allocator.free(owners);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    for (spans, 0..) |span, i| {
        popEnded(&stack, spans, span);
        owners[i] = innermostOpen(spans, stack.items, span);
        if (span.kind == .function) try stack.append(allocator, i);
    }

    return owners;
}

/// A span that extends past the top of the stack cannot be contained by it;
/// syntax spans never partially overlap, so the top has ended and is done.
fn popEnded(stack: *std.ArrayList(usize), spans: []const Span, span: Span) void {
    while (stack.items.len > 0 and span.end > spans[stack.items[stack.items.len - 1]].end) {
        _ = stack.pop();
    }
}

fn innermostOpen(spans: []const Span, stack: []const usize, span: Span) ?usize {
    var i = stack.len;
    while (i > 0) {
        i -= 1;
        // containsSpan rejects an identical range: that entry is the span
        // itself (the query root is captured too), not a container of it.
        if (containsSpan(spans[stack[i]], span)) return stack[i];
    }
    return null;
}

pub fn complexityOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    node: Node,
) std.mem.Allocator.Error!u32 {
    const analysis = try analyze(allocator, compiled, node);
    defer analysis.deinit(allocator);

    var cc: u32 = 1;
    for (analysis.spans, analysis.owners) |p, owner| {
        if (!isComplexityPoint(p.kind)) continue;
        if (!ownedByRoot(analysis.spans, owner, node)) continue;
        cc += 1;
    }

    return cc;
}

pub fn nestingOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    node: Node,
) std.mem.Allocator.Error!u32 {
    const analysis = try analyze(allocator, compiled, node);
    defer analysis.deinit(allocator);

    // Collapse ownership to one class: constructs belonging to `node` share a
    // key, constructs inside nested functions drop out entirely.
    const keys = try allocator.alloc(?usize, analysis.spans.len);
    defer allocator.free(keys);
    for (keys, analysis.owners) |*key, owner| {
        key.* = if (ownedByRoot(analysis.spans, owner, node)) 0 else null;
    }

    const depths = try nestingDepths(allocator, analysis.spans, keys);
    defer allocator.free(depths);

    var deepest: u32 = 0;
    for (depths) |depth| deepest = @max(deepest, depth);

    return deepest;
}

/// A span collected under `node` belongs to `node` itself when no captured
/// function strictly contains it, or when the innermost one is `node` (the
/// query root is captured too, so it shows up as a function span).
fn ownedByRoot(spans: []const Span, owner: ?usize, node: Node) bool {
    const fi = owner orelse return true;
    const f = spans[fi];
    return f.start == node.startByte() and f.end == node.endByte();
}

pub fn positionOf(node: Node) ?u32 {
    if (node.parent() == null) return null;
    var ordinal: u32 = 1;
    var current = node;
    while (current.prevNamedSibling()) |prev| {
        ordinal += 1;
        current = prev;
    }
    return ordinal;
}

pub fn siblingsOf(node: Node) ?u32 {
    const container = node.parent() orelse return null;
    return container.namedChildCount();
}

pub fn lengthOf(node: Node) u32 {
    return node.endPoint().row - node.startPoint().row + 1;
}

pub fn paramsOf(node: Node, fam: family_mod.Family) ?u32 {
    if (node.childByFieldName("parameters")) |params| {
        return family_mod.of(fam).paramCount(params);
    }
    if (node.childByFieldName("parameter") != null) return 1;
    return null;
}

pub fn countNonExtraNamed(node: Node) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (child.isExtra()) continue;
        count += 1;
    }
    return count;
}

pub fn argsOf(node: Node) ?u32 {
    const arguments = node.childByFieldName("arguments") orelse return null;
    return countNonExtraNamed(arguments);
}

fn collectSpans(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    root: Node,
    spans: *std.ArrayList(Span),
) !void {
    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);

    while (stack.pop()) |node| {
        if (classify(compiled.table, node)) |kind| {
            try spans.append(allocator, .{
                .kind = kind,
                .start = node.startByte(),
                .end = node.endByte(),
            });
        }

        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| try stack.append(allocator, child);
        }
    }
}

/// Start ascending, end descending: an enclosing span always sorts before the
/// spans it contains.
fn spanLessThan(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

fn containsSpan(outer: Span, inner: Span) bool {
    if (outer.start == inner.start and outer.end == inner.end) return false;
    return outer.start <= inner.start and inner.end <= outer.end;
}

const Container = struct {
    kind: MetricKind,
    end: u32,
};

/// Depth of every nesting construct: 1 + the number of enclosing levels that
/// share its owner key (spans with a null key, or that are not nesting
/// constructs, get depth 0). Containers sharing a kind and end byte collapse
/// into one level: the nested if_statements of an `else if` chain all end at
/// the same byte, so a chain counts as a single level of indentation. The
/// construct's own (kind, end) is excluded for the same reason — an `else if`
/// link sits at the depth of its chain head, not one below it.
fn nestingDepths(
    allocator: std.mem.Allocator,
    spans: []const Span,
    keys: []const ?usize,
) std.mem.Allocator.Error![]u32 {
    const depths = try allocator.alloc(u32, spans.len);
    errdefer allocator.free(depths);
    @memset(depths, 0);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);
    var levels: std.ArrayList(Container) = .empty;
    defer levels.deinit(allocator);

    for (spans, 0..) |span, i| {
        popEnded(&stack, spans, span);
        if (!isNestingConstruct(span.kind)) continue;
        const key = keys[i] orelse continue;

        levels.clearRetainingCapacity();
        for (stack.items) |pi| {
            const p_key = keys[pi] orelse continue;
            if (p_key != key) continue;
            const p = spans[pi];
            if (!containsSpan(p, span)) continue;
            const entry: Container = .{ .kind = p.kind, .end = p.end };
            if (entry.kind == span.kind and entry.end == span.end) continue;
            if (!hasContainer(levels.items, entry)) try levels.append(allocator, entry);
        }

        depths[i] = @intCast(levels.items.len + 1);
        try stack.append(allocator, i);
    }

    return depths;
}

fn hasContainer(containers: []const Container, entry: Container) bool {
    for (containers) |c| {
        if (c.kind == entry.kind and c.end == entry.end) return true;
    }
    return false;
}

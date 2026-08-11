const std = @import("std");

const family_mod = @import("family/family.zig");
const OpenSpanStack = @import("open_span_stack.zig").OpenSpanStack;
const Node = @import("node.zig").Node;

const ByteInterval = OpenSpanStack.Interval;

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

pub const Measures = struct {
    complexity: u32,
    nesting: u32,
};

/// Analysis owns its slices until deinit.
pub const Analysis = struct {
    allocator: std.mem.Allocator,
    spans: []const Span,
    owners: []const ?usize,
    root_start: u32,
    root_end: u32,

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.owners);
        self.allocator.free(self.spans);
        self.* = undefined;
    }

    pub fn measures(self: *const Analysis) std.mem.Allocator.Error!Measures {
        var complexity: u32 = 1;
        for (self.spans, self.owners) |span, owner| {
            if (!isComplexityPoint(span.kind)) continue;
            if (!ownedByRoot(self.spans, owner, self.root_start, self.root_end)) continue;
            complexity += 1;
        }

        const keys = try self.allocator.alloc(?usize, self.spans.len);
        defer self.allocator.free(keys);
        for (keys, self.owners) |*key, owner| {
            key.* = if (ownedByRoot(self.spans, owner, self.root_start, self.root_end)) 0 else null;
        }

        const depths = try nestingDepths(self.allocator, self.spans, keys);
        defer self.allocator.free(depths);

        var nesting: u32 = 0;
        for (depths) |depth| nesting = @max(nesting, depth);

        return .{ .complexity = complexity, .nesting = nesting };
    }
};

const Container = struct {
    kind: MetricKind,
    end: u32,
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

pub fn analyze(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    root: Node,
) std.mem.Allocator.Error!Analysis {
    var list: std.ArrayList(Span) = .empty;
    errdefer list.deinit(allocator);
    try collectSpans(allocator, compiled, root, &list);

    const spans = try list.toOwnedSlice(allocator);
    errdefer allocator.free(spans);
    const owners = try computeOwners(allocator, spans);

    return .{
        .allocator = allocator,
        .spans = spans,
        .owners = owners,
        .root_start = root.startByte(),
        .root_end = root.endByte(),
    };
}

fn computeOwners(allocator: std.mem.Allocator, spans: []const Span) std.mem.Allocator.Error![]?usize {
    const owners = try allocator.alloc(?usize, spans.len);
    errdefer allocator.free(owners);

    var open_spans = try OpenSpanStack.init(allocator, spans.len);
    defer open_spans.deinit();

    for (spans, 0..) |span, i| {
        open_spans.prepare(spanInterval(span));
        owners[i] = innermostOpen(spans, open_spans.items(), span);
        if (span.kind == .function) open_spans.push(i, spanInterval(span));
    }

    return owners;
}

fn innermostOpen(spans: []const Span, open_spans: []const OpenSpanStack.Entry, span: Span) ?usize {
    var i = open_spans.len;
    while (i > 0) {
        i -= 1;
        const index = open_spans[i].index;
        if (containsSpan(spans[index], span)) return index;
    }
    return null;
}

pub fn complexityOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    node: Node,
) std.mem.Allocator.Error!u32 {
    var analysis = try analyze(allocator, compiled, node);
    defer analysis.deinit();

    return (try analysis.measures()).complexity;
}

pub fn nestingOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    node: Node,
) std.mem.Allocator.Error!u32 {
    var analysis = try analyze(allocator, compiled, node);
    defer analysis.deinit();

    return (try analysis.measures()).nesting;
}

/// a span collected under `node` belongs to `node` itself when no captured
/// function strictly contains it, or when the innermost one is `node` (the
/// query root is captured too, so it shows up as a function span).
fn ownedByRoot(spans: []const Span, owner: ?usize, root_start: u32, root_end: u32) bool {
    const fi = owner orelse return true;
    const f = spans[fi];
    return f.start == root_start and f.end == root_end;
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
    var children = node.namedChildren();
    while (children.next()) |child| {
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
    var nodes = root.preorder();
    while (nodes.next()) |node| {
        if (classify(compiled.table, node)) |kind| {
            try spans.append(allocator, .{
                .kind = kind,
                .start = node.startByte(),
                .end = node.endByte(),
            });
        }
    }
}

fn containsSpan(outer: Span, inner: Span) bool {
    return spanInterval(outer).strictlyContains(spanInterval(inner));
}

fn spanInterval(span: Span) ByteInterval {
    return .init(span.start, span.end);
}

/// depth of every nesting construct: 1 + the number of enclosing levels that
/// share its owner key (spans with a null key, or that are not nesting
/// constructs, get depth 0). containers sharing a kind and end byte collapse
/// into one level: the nested if_statements of an `else if` chain all end at
/// the same byte, so a chain counts as a single level of indentation. the
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

    var open_spans = try OpenSpanStack.init(allocator, spans.len);
    defer open_spans.deinit();
    var levels: std.ArrayList(Container) = .empty;
    defer levels.deinit(allocator);

    for (spans, 0..) |span, i| {
        open_spans.prepare(spanInterval(span));

        if (!isNestingConstruct(span.kind)) continue;
        const key = keys[i] orelse continue;

        levels.clearRetainingCapacity();
        for (open_spans.items()) |open_span| {
            const pi = open_span.index;
            const p_key = keys[pi] orelse continue;
            if (p_key != key) continue;

            const p = spans[pi];
            if (!containsSpan(p, span)) continue;
            const entry: Container = .{ .kind = p.kind, .end = p.end };

            if (entry.kind == span.kind and entry.end == span.end) continue;
            if (!hasContainer(levels.items, entry)) try levels.append(allocator, entry);
        }

        depths[i] = @intCast(levels.items.len + 1);

        open_spans.push(i, spanInterval(span));
    }

    return depths;
}

fn hasContainer(containers: []const Container, entry: Container) bool {
    for (containers) |c| {
        if (c.kind == entry.kind and c.end == entry.end) return true;
    }

    return false;
}

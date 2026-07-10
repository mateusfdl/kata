const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const kinds = @import("kinds.zig");
const language = @import("language.zig");
const Node = @import("node.zig").Node;

const MetricKind = kinds.MetricKind;

pub const Name = enum {
    complexity,
    nesting_depth,
    function_length,

    pub fn toString(self: Name) []const u8 {
        return switch (self) {
            .complexity => "complexity",
            .nesting_depth => "nesting-depth",
            .function_length => "function-length",
        };
    }

    pub fn fromString(s: []const u8) ?Name {
        for (std.enums.values(Name)) |n| {
            if (std.mem.eql(u8, s, n.toString())) return n;
        }
        return null;
    }
};

pub const Set = std.EnumArray(Name, ?u32);

pub const empty: Set = .initFill(null);

pub fn anyEnabled(set: Set) bool {
    for (std.enums.values(Name)) |n| {
        if (set.get(n) != null) return true;
    }

    return false;
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
    lang: language.Name,
) std.mem.Allocator.Error!Compiled {
    const table = switch (lang) {
        .ts, .tsx => try kinds.buildTsTable(allocator),
        .go => try kinds.buildGoTable(allocator),
    };
    return .{ .table = table };
}

const Span = struct {
    kind: MetricKind,
    start: u32,
    end: u32,
    range: diagnostic.Range,
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

pub fn run(
    allocator: std.mem.Allocator,
    set: Set,
    compiled: *const Compiled,
    root: Node,
    lang: language.Name,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const analysis = try analyze(allocator, compiled, root);
    defer analysis.deinit(allocator);

    const lang_str = lang.toString();

    if (set.get(.function_length)) |max| try checkFunctionLength(allocator, analysis.spans, max, lang_str, out);
    if (set.get(.complexity)) |max| try checkComplexity(allocator, analysis.spans, analysis.owners, max, lang_str, out);
    if (set.get(.nesting_depth)) |max| try checkNestingDepth(allocator, analysis.spans, analysis.owners, max, lang_str, out);
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

pub fn paramsOf(node: Node, lang: language.Name) ?u32 {
    if (node.childByFieldName("parameters")) |params| {
        return switch (lang) {
            .ts, .tsx => countNonExtraNamed(params),
            .go => goParamCount(params),
        };
    }
    if (node.childByFieldName("parameter") != null) return 1;
    return null;
}

fn goParamCount(params: Node) u32 {
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < params.namedChildCount()) : (i += 1) {
        const decl = params.namedChild(i) orelse continue;
        if (!isGoParameterDeclaration(decl)) continue;
        const names = countFieldChildren(decl, "name");
        total += if (names == 0) 1 else names;
    }
    return total;
}

fn isGoParameterDeclaration(node: Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "parameter_declaration") or
        std.mem.eql(u8, kind, "variadic_parameter_declaration");
}

fn countNonExtraNamed(node: Node) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (child.isExtra()) continue;
        count += 1;
    }
    return count;
}

fn countFieldChildren(node: Node, field: []const u8) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const name = node.fieldNameForChild(i) orelse continue;
        if (std.mem.eql(u8, name, field)) count += 1;
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
        if (kinds.classify(compiled.table, node)) |kind| {
            const sp = node.startPoint();
            const ep = node.endPoint();
            try spans.append(allocator, .{
                .kind = kind,
                .start = node.startByte(),
                .end = node.endByte(),
                .range = .{
                    .start = .{ .line = sp.row, .column = sp.column },
                    .end = .{ .line = ep.row, .column = ep.column },
                },
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

fn checkFunctionLength(
    allocator: std.mem.Allocator,
    spans: []const Span,
    max: u32,
    lang_str: []const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    for (spans) |span| {
        if (span.kind != .function) continue;
        const lines = span.range.end.line - span.range.start.line + 1;
        if (lines <= max) continue;
        try emit(allocator, out, .function_length, lang_str, span.range, "function length {d} exceeds max {d}", .{ lines, max });
    }
}

fn checkComplexity(
    allocator: std.mem.Allocator,
    spans: []const Span,
    owners: []const ?usize,
    max: u32,
    lang_str: []const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const counts = try allocator.alloc(u32, spans.len);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (spans, owners) |p, owner| {
        if (!isComplexityPoint(p.kind)) continue;
        const fi = owner orelse continue;
        counts[fi] += 1;
    }

    for (spans, counts) |f, count| {
        if (f.kind != .function) continue;
        const cc = count + 1;
        if (cc <= max) continue;
        try emit(allocator, out, .complexity, lang_str, f.range, "cyclomatic complexity {d} exceeds max {d}", .{ cc, max });
    }
}

const Container = struct {
    kind: MetricKind,
    end: u32,
};

fn checkNestingDepth(
    allocator: std.mem.Allocator,
    spans: []const Span,
    owners: []const ?usize,
    max: u32,
    lang_str: []const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const depths = try nestingDepths(allocator, spans, owners);
    defer allocator.free(depths);

    for (spans, depths) |n, depth| {
        // Report only the construct at exactly max + 1: any deeper chain
        // always passes through max + 1 on the way down, so this yields one
        // diagnostic per offending chain instead of one per extra level.
        if (depth != max + 1) continue;
        try emit(allocator, out, .nesting_depth, lang_str, n.range, "nesting depth {d} exceeds max {d}", .{ depth, max });
    }
}

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

fn emit(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(diagnostic.Diagnostic),
    name: Name,
    lang_str: []const u8,
    range: diagnostic.Range,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try out.append(allocator, .{
        .rule_id = name.toString(),
        .language = lang_str,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
        .range = range,
    });
}

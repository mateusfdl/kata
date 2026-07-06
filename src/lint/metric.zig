const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");

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

const Kind = enum {
    function,
    branch,
    ternary,
    loop,
    case,
    switch_stmt,
    catch_clause,
    bool_op,
};

fn kindFromCaptureName(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "function")) return .function;
    if (std.mem.eql(u8, name, "branch")) return .branch;
    if (std.mem.eql(u8, name, "ternary")) return .ternary;
    if (std.mem.eql(u8, name, "loop")) return .loop;
    if (std.mem.eql(u8, name, "case")) return .case;
    if (std.mem.eql(u8, name, "switch")) return .switch_stmt;
    if (std.mem.eql(u8, name, "catch")) return .catch_clause;
    if (std.mem.eql(u8, name, "bool-op")) return .bool_op;

    return null;
}

fn isComplexityPoint(kind: Kind) bool {
    return switch (kind) {
        .branch, .ternary, .loop, .case, .catch_clause, .bool_op => true,
        .function, .switch_stmt => false,
    };
}

fn isNestingConstruct(kind: Kind) bool {
    return switch (kind) {
        .branch, .loop, .switch_stmt, .catch_clause => true,
        .function, .ternary, .case, .bool_op => false,
    };
}

const ts_query_source =
    \\(function_declaration) @function
    \\(function_expression) @function
    \\(generator_function_declaration) @function
    \\(generator_function) @function
    \\(arrow_function) @function
    \\(method_definition) @function
    \\(if_statement) @branch
    \\(ternary_expression) @ternary
    \\(for_statement) @loop
    \\(for_in_statement) @loop
    \\(while_statement) @loop
    \\(do_statement) @loop
    \\(switch_statement) @switch
    \\(switch_case) @case
    \\(catch_clause) @catch
    \\(binary_expression operator: "&&") @bool-op
    \\(binary_expression operator: "||") @bool-op
    \\(binary_expression operator: "??") @bool-op
;

const go_query_source =
    \\(function_declaration) @function
    \\(method_declaration) @function
    \\(func_literal) @function
    \\(if_statement) @branch
    \\(for_statement) @loop
    \\(expression_switch_statement) @switch
    \\(type_switch_statement) @switch
    \\(select_statement) @switch
    \\(expression_case) @case
    \\(type_case) @case
    \\(communication_case) @case
    \\(binary_expression operator: "&&") @bool-op
    \\(binary_expression operator: "||") @bool-op
;

pub fn querySource(lang: language.Name) []const u8 {
    return switch (lang) {
        .ts, .tsx => ts_query_source,
        .go => go_query_source,
    };
}

pub const Compiled = struct {
    query: *ts.Query,
    capture_kinds: []const Kind,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        self.query.destroy();
        allocator.free(self.capture_kinds);
    }
};

pub const CompileError = error{MetricQueryCompileFailed} || std.mem.Allocator.Error;

pub fn compile(
    allocator: std.mem.Allocator,
    ts_lang: *const ts.Language,
    lang: language.Name,
) CompileError!Compiled {
    var error_offset: u32 = 0;
    const query = ts.Query.create(ts_lang, querySource(lang), &error_offset) catch
        return error.MetricQueryCompileFailed;
    errdefer query.destroy();

    const kinds = try allocator.alloc(Kind, query.captureCount());
    errdefer allocator.free(kinds);

    for (kinds, 0..) |*kind, i| {
        const cap_name = query.captureNameForId(@intCast(i)) orelse return error.MetricQueryCompileFailed;
        kind.* = kindFromCaptureName(cap_name) orelse return error.MetricQueryCompileFailed;
    }

    return .{ .query = query, .capture_kinds = kinds };
}

const Span = struct {
    kind: Kind,
    start: u32,
    end: u32,
    range: diagnostic.Range,
};

pub fn run(
    allocator: std.mem.Allocator,
    set: Set,
    compiled: *const Compiled,
    cursor: *ts.QueryCursor,
    root: ts.Node,
    lang: language.Name,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    try collectSpans(allocator, compiled, cursor, root, &spans);
    std.mem.sort(Span, spans.items, {}, spanLessThan);

    const owners = try allocator.alloc(?usize, spans.items.len);
    defer allocator.free(owners);

    for (spans.items, 0..) |span, i| {
        owners[i] = if (span.kind == .function) null else innermostFunction(spans.items, span);
    }

    const lang_str = lang.toString();

    if (set.get(.function_length)) |max| try checkFunctionLength(allocator, spans.items, max, lang_str, out);
    if (set.get(.complexity)) |max| try checkComplexity(allocator, spans.items, owners, max, lang_str, out);
    if (set.get(.nesting_depth)) |max| try checkNestingDepth(allocator, spans.items, owners, max, lang_str, out);
}

pub fn complexityOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    cursor: *ts.QueryCursor,
    node: ts.Node,
) std.mem.Allocator.Error!u32 {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    try collectSpans(allocator, compiled, cursor, node, &spans);

    var cc: u32 = 1;

    for (spans.items) |p| {
        if (!isComplexityPoint(p.kind)) continue;
        if (!ownedByNode(spans.items, p, node)) continue;
        cc += 1;
    }

    return cc;
}

pub fn nestingOf(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    cursor: *ts.QueryCursor,
    node: ts.Node,
) std.mem.Allocator.Error!u32 {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    try collectSpans(allocator, compiled, cursor, node, &spans);

    var containers: std.ArrayList(Container) = .empty;
    defer containers.deinit(allocator);

    var deepest: u32 = 0;
    for (spans.items, 0..) |n, ni| {
        if (!isNestingConstruct(n.kind)) continue;
        if (!ownedByNode(spans.items, n, node)) continue;

        containers.clearRetainingCapacity();
        for (spans.items, 0..) |p, pi| {
            if (pi == ni) continue;
            if (!isNestingConstruct(p.kind)) continue;
            if (!ownedByNode(spans.items, p, node)) continue;
            if (!containsSpan(p, n)) continue;
            const entry: Container = .{ .kind = p.kind, .end = p.end };
            if (entry.kind == n.kind and entry.end == n.end) continue;
            if (!hasContainer(containers.items, entry)) try containers.append(allocator, entry);
        }

        const depth: u32 = @intCast(containers.items.len + 1);
        if (depth > deepest) deepest = depth;
    }
    return deepest;
}

pub fn positionOf(node: ts.Node) ?u32 {
    if (node.parent() == null) return null;
    var ordinal: u32 = 1;
    var current = node;
    while (current.prevNamedSibling()) |prev| {
        ordinal += 1;
        current = prev;
    }
    return ordinal;
}

pub fn siblingsOf(node: ts.Node) ?u32 {
    const container = node.parent() orelse return null;
    return container.namedChildCount();
}

pub fn lengthOf(node: ts.Node) u32 {
    return node.endPoint().row - node.startPoint().row + 1;
}

pub fn paramsOf(node: ts.Node, lang: language.Name) ?u32 {
    if (node.childByFieldName("parameters")) |params| {
        return switch (lang) {
            .ts, .tsx => countNonExtraNamed(params),
            .go => goParamCount(params),
        };
    }
    if (node.childByFieldName("parameter") != null) return 1;
    return null;
}

fn goParamCount(params: ts.Node) u32 {
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

fn isGoParameterDeclaration(node: ts.Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "parameter_declaration") or
        std.mem.eql(u8, kind, "variadic_parameter_declaration");
}

fn countNonExtraNamed(node: ts.Node) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (child.isExtra()) continue;
        count += 1;
    }
    return count;
}

fn countFieldChildren(node: ts.Node, field: []const u8) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const name = node.fieldNameForChild(i) orelse continue;
        if (std.mem.eql(u8, name, field)) count += 1;
    }
    return count;
}

pub fn argsOf(node: ts.Node) ?u32 {
    const arguments = node.childByFieldName("arguments") orelse return null;
    return countNonExtraNamed(arguments);
}

fn ownedByNode(spans: []const Span, p: Span, node: ts.Node) bool {
    const owner = innermostFunction(spans, p) orelse return true;
    const f = spans[owner];
    return f.start == node.startByte() and f.end == node.endByte();
}

fn collectSpans(
    allocator: std.mem.Allocator,
    compiled: *const Compiled,
    cursor: *ts.QueryCursor,
    root: ts.Node,
    spans: *std.ArrayList(Span),
) !void {
    cursor.exec(compiled.query, root);
    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const sp = cap.node.startPoint();
            const ep = cap.node.endPoint();
            try spans.append(allocator, .{
                .kind = compiled.capture_kinds[cap.index],
                .start = cap.node.startByte(),
                .end = cap.node.endByte(),
                .range = .{
                    .start = .{ .line = sp.row, .column = sp.column },
                    .end = .{ .line = ep.row, .column = ep.column },
                },
            });
        }
    }
}

fn spanLessThan(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

fn containsSpan(outer: Span, inner: Span) bool {
    if (outer.start == inner.start and outer.end == inner.end) return false;
    return outer.start <= inner.start and inner.end <= outer.end;
}

fn innermostFunction(spans: []const Span, p: Span) ?usize {
    var best: ?usize = null;
    for (spans, 0..) |f, fi| {
        if (f.kind != .function) continue;
        if (!containsSpan(f, p)) continue;
        if (best == null or spans[best.?].start < f.start) best = fi;
    }
    return best;
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
    for (spans, 0..) |f, fi| {
        if (f.kind != .function) continue;
        var cc: u32 = 1;
        for (spans, 0..) |p, pi| {
            if (!isComplexityPoint(p.kind)) continue;
            const owner = owners[pi] orelse continue;
            if (owner == fi) cc += 1;
        }
        if (cc <= max) continue;
        try emit(allocator, out, .complexity, lang_str, f.range, "cyclomatic complexity {d} exceeds max {d}", .{ cc, max });
    }
}

const Container = struct {
    kind: Kind,
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
    var containers: std.ArrayList(Container) = .empty;
    defer containers.deinit(allocator);

    for (spans, 0..) |n, ni| {
        if (!isNestingConstruct(n.kind)) continue;
        const owner = owners[ni] orelse continue;

        containers.clearRetainingCapacity();
        for (spans, 0..) |p, pi| {
            if (pi == ni) continue;
            if (!isNestingConstruct(p.kind)) continue;
            const p_owner = owners[pi] orelse continue;
            if (p_owner != owner) continue;
            if (!containsSpan(p, n)) continue;
            const entry: Container = .{ .kind = p.kind, .end = p.end };
            if (entry.kind == n.kind and entry.end == n.end) continue;
            if (!hasContainer(containers.items, entry)) try containers.append(allocator, entry);
        }

        const depth: u32 = @intCast(containers.items.len + 1);
        if (depth != max + 1) continue;
        try emit(allocator, out, .nesting_depth, lang_str, n.range, "nesting depth {d} exceeds max {d}", .{ depth, max });
    }
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

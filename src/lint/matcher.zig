const std = @import("std");
const ts = @import("tree_sitter");

const expr = @import("expr.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");
const metric = @import("metric.zig");
const rule = @import("rule.zig");

pub const MetricContext = struct {
    allocator: std.mem.Allocator,
    compiled: *const metric.Compiled,
    cursor: *ts.QueryCursor,
    lang: language.Name,
};

pub const EvalContext = struct {
    source: []const u8,
    root: ts.Node,
    metric: ?MetricContext = null,
    nested_cursor: ?*ts.QueryCursor = null,
};

pub fn evaluate(
    predicates: []const rule.Predicate,
    match: ts.Query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    for (predicates) |pred| {
        switch (pred) {
            .eq => |args| if (!evalEq(args, match, ctx.source, false)) return false,
            .not_eq => |args| if (!evalEq(args, match, ctx.source, true)) return false,
            .any_of => |args| if (!evalAnyOf(args, match, ctx.source, false)) return false,
            .not_any_of => |args| if (!evalAnyOf(args, match, ctx.source, true)) return false,
            .match => |p| if (!evalMatch(p, match, ctx.source, false)) return false,
            .not_match => |p| if (!evalMatch(p, match, ctx.source, true)) return false,
            .starts_with => |args| if (!evalStringHelper(args, match, ctx.source, .starts_with, false)) return false,
            .not_starts_with => |args| if (!evalStringHelper(args, match, ctx.source, .starts_with, true)) return false,
            .ends_with => |args| if (!evalStringHelper(args, match, ctx.source, .ends_with, false)) return false,
            .not_ends_with => |args| if (!evalStringHelper(args, match, ctx.source, .ends_with, true)) return false,
            .contains => |args| if (!evalStringHelper(args, match, ctx.source, .contains, false)) return false,
            .not_contains => |args| if (!evalStringHelper(args, match, ctx.source, .contains, true)) return false,
            .glob => |args| if (!evalStringHelper(args, match, ctx.source, .glob, false)) return false,
            .not_glob => |args| if (!evalStringHelper(args, match, ctx.source, .glob, true)) return false,
            .captured => |args| if (!evalCaptured(args, match, false)) return false,
            .not_captured => |args| if (!evalCaptured(args, match, true)) return false,
            .where => |where| if (!try evalWhere(where, match, ctx)) return false,
            .has => |p| if (!try evalHas(p, match, ctx, false)) return false,
            .not_has => |p| if (!try evalHas(p, match, ctx, true)) return false,
            .inside => |p| if (!try evalInside(p, match, ctx, false)) return false,
            .not_inside => |p| if (!try evalInside(p, match, ctx, true)) return false,
            .parent => |p| if (!try evalParent(p, match, ctx, false)) return false,
            .not_parent => |p| if (!try evalParent(p, match, ctx, true)) return false,
            .count => |p| if (!try evalCount(p, match, ctx)) return false,
        }
    }
    return true;
}

fn evalWhere(
    parsed: *const expr.Expr,
    match: ts.Query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const metric_ctx = ctx.metric orelse return false;
    const measures: NodeMeasures = .{ .ctx = metric_ctx, .match = match, .source = ctx.source };

    return expr.evaluate(parsed, measures);
}

fn evalHas(
    pred: rule.NestedPredicate,
    match: ts.Query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    const cursor = ctx.nested_cursor orelse return false;
    const subject = subjectNode(pred.args, match) orelse return false;

    cursor.exec(pred.matcher.query, subject);
    while (cursor.nextMatch()) |nested_match| {
        if (try nestedMatchPasses(pred.matcher, nested_match, subject, ctx)) return !negate;
    }

    return negate;
}

fn evalInside(
    pred: rule.NestedPredicate,
    match: ts.Query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    const cursor = ctx.nested_cursor orelse return false;
    const subject = subjectNode(pred.args, match) orelse return false;

    cursor.exec(pred.matcher.query, ctx.root);
    while (cursor.nextMatch()) |nested_match| {
        const enclosing = findCaptureNode(pred.matcher.root_capture_id, nested_match) orelse continue;
        if (!strictlyContains(enclosing, subject)) continue;
        if (try evaluate(pred.matcher.predicates, nested_match, ctx)) return !negate;
    }

    return negate;
}

fn evalParent(
    pred: rule.NestedPredicate,
    match: ts.Query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    const cursor = ctx.nested_cursor orelse return false;
    const subject = subjectNode(pred.args, match) orelse return false;

    cursor.exec(pred.matcher.query, ctx.root);
    while (cursor.nextMatch()) |nested_match| {
        const candidate = findCaptureNode(pred.matcher.root_capture_id, nested_match) orelse continue;
        if (!isDirectParent(candidate, subject)) continue;
        if (try evaluate(pred.matcher.predicates, nested_match, ctx)) return !negate;
    }

    return negate;
}

fn isDirectParent(candidate: ts.Node, subject: ts.Node) bool {
    const p = subject.parent() orelse return false;
    return p.eql(candidate);
}

fn evalCount(
    pred: rule.CountPredicate,
    match: ts.Query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const cursor = ctx.nested_cursor orelse return false;
    const subject = subjectNode(pred.args, match) orelse return false;

    cursor.exec(pred.matcher.query, subject);
    var total: u32 = 0;
    while (cursor.nextMatch()) |nested_match| {
        if (try nestedMatchPasses(pred.matcher, nested_match, subject, ctx)) total += 1;
    }

    return compareCount(pred.compare.op, total, pred.compare.value);
}

fn nestedMatchPasses(
    nested: *const rule.NestedMatcher,
    nested_match: ts.Query.Match,
    subject: ts.Node,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const root_node = findCaptureNode(nested.root_capture_id, nested_match) orelse return false;
    if (sameRange(root_node, subject)) return false;

    return evaluate(nested.predicates, nested_match, ctx);
}

fn subjectNode(args: []const rule.PredicateOperand, match: ts.Query.Match) ?ts.Node {
    if (args.len != 1) return null;

    return switch (args[0]) {
        .capture => |id| findCaptureNode(id, match),
        .string => null,
    };
}

fn strictlyContains(enclosing: ts.Node, node: ts.Node) bool {
    if (sameRange(enclosing, node)) return false;

    return enclosing.startByte() <= node.startByte() and node.endByte() <= enclosing.endByte();
}

fn sameRange(a: ts.Node, b: ts.Node) bool {
    return a.startByte() == b.startByte() and a.endByte() == b.endByte();
}

fn compareCount(op: expr.Compare, left: u32, right: u32) bool {
    return switch (op) {
        .eq => left == right,
        .ne => left != right,
        .gt => left > right,
        .ge => left >= right,
        .lt => left < right,
        .le => left <= right,
    };
}

const NodeMeasures = struct {
    ctx: MetricContext,
    match: ts.Query.Match,
    source: []const u8,

    pub const Error = std.mem.Allocator.Error;

    pub fn measure(self: NodeMeasures, m: expr.Measure, capture_id: u32) Error!?u32 {
        const node = findCaptureNode(capture_id, self.match) orelse return null;

        return switch (m) {
            .complexity => try metric.complexityOf(self.ctx.allocator, self.ctx.compiled, self.ctx.cursor, node),
            .nesting => try metric.nestingOf(self.ctx.allocator, self.ctx.compiled, self.ctx.cursor, node),
            .length => metric.lengthOf(node),
            .text => self.numericText(node),
            .params => metric.paramsOf(node, self.ctx.lang),
            .args => metric.argsOf(node),
            .position => metric.positionOf(node),
            .siblings => metric.siblingsOf(node),
        };
    }

    fn numericText(self: NodeMeasures, node: ts.Node) ?u32 {
        const end = node.endByte();

        if (end > self.source.len) return null;

        const text = self.source[node.startByte()..end];

        return std.fmt.parseInt(u32, text, 10) catch null;
    }
};

pub fn renderMessage(
    allocator: std.mem.Allocator,
    segments: []const rule.MessageSegment,
    match: ts.Query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(allocator, text),
            .placeholder => |p| try renderPlaceholder(allocator, &out, p, match, ctx),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn renderPlaceholder(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    p: rule.Placeholder,
    match: ts.Query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!void {
    if (p.measure == .text) {
        const text = findCaptureText(p.capture_id, match, ctx.source) orelse "?";

        return out.appendSlice(allocator, text);
    }

    const metric_ctx = ctx.metric orelse return out.appendSlice(allocator, "?");
    const measures: NodeMeasures = .{ .ctx = metric_ctx, .match = match, .source = ctx.source };
    const value = (try measures.measure(p.measure, p.capture_id)) orelse return out.appendSlice(allocator, "?");
    var buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;

    try out.appendSlice(allocator, rendered);
}

fn evalEq(
    args: []const rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (args.len != 2) return false;

    const left_text = resolveText(args[0], match, source) orelse return false;
    const right_text = resolveText(args[1], match, source) orelse return false;

    return std.mem.eql(u8, left_text, right_text) != negate;
}

fn evalAnyOf(
    args: []const rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (args.len < 2) return false;

    const left_text = resolveText(args[0], match, source) orelse return false;

    for (args[1..]) |arg| {
        const candidate = resolveText(arg, match, source) orelse continue;
        if (std.mem.eql(u8, left_text, candidate)) return !negate;
    }

    return negate;
}

fn evalCaptured(args: []const rule.PredicateOperand, match: ts.Query.Match, negate: bool) bool {
    if (args.len != 1) return false;

    const present = switch (args[0]) {
        .capture => |id| findCaptureNode(id, match) != null,
        .string => false,
    };

    return present != negate;
}

const StringHelper = enum { starts_with, ends_with, contains, glob };

fn evalStringHelper(
    args: []const rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
    helper: StringHelper,
    negate: bool,
) bool {
    if (args.len != 2) return false;

    const subject = resolveText(args[0], match, source) orelse return false;
    const candidate = resolveText(args[1], match, source) orelse return false;
    const found = switch (helper) {
        .starts_with => std.mem.startsWith(u8, subject, candidate),
        .ends_with => std.mem.endsWith(u8, subject, candidate),
        .contains => std.mem.indexOf(u8, subject, candidate) != null,
        .glob => glob.match(candidate, subject),
    };

    return found != negate;
}

fn evalMatch(
    pred: rule.RegexPredicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    const text = resolveText(pred.args[0], match, source) orelse return false;

    return pred.regex.isMatch(text) != negate;
}

fn resolveText(
    operand: rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    return switch (operand) {
        .string => |s| s,
        .capture => |id| findCaptureText(id, match, source),
    };
}

fn findCaptureText(
    id: u32,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    const node = findCaptureNode(id, match) orelse return null;
    const start = node.startByte();
    const end = node.endByte();

    if (end > source.len) return null;

    return source[start..end];
}

fn findCaptureNode(id: u32, match: ts.Query.Match) ?ts.Node {
    for (match.captures) |cap| {
        if (cap.index == id) return cap.node;
    }

    return null;
}

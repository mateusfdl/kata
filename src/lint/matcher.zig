const std = @import("std");
const ts = @import("tree_sitter");

const expr = @import("expr.zig");
const language = @import("language.zig");
const metric = @import("metric.zig");
const rule = @import("rule.zig");

pub const MetricContext = struct {
    allocator: std.mem.Allocator,
    compiled: *const metric.Compiled,
    cursor: *ts.QueryCursor,
    lang: language.Name,
};

pub fn evaluate(
    predicates: []const rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    metric_ctx: ?MetricContext,
) std.mem.Allocator.Error!bool {
    for (predicates) |pred| {
        switch (pred.op) {
            .eq => if (!evalEq(pred, match, source, false)) return false,
            .not_eq => if (!evalEq(pred, match, source, true)) return false,
            .any_of => if (!evalAnyOf(pred, match, source, false)) return false,
            .not_any_of => if (!evalAnyOf(pred, match, source, true)) return false,
            .match => if (!evalMatch(pred, match, source, false)) return false,
            .not_match => if (!evalMatch(pred, match, source, true)) return false,
            .where => if (!try evalWhere(pred, match, source, metric_ctx)) return false,
        }
    }
    return true;
}

fn evalWhere(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    metric_ctx: ?MetricContext,
) std.mem.Allocator.Error!bool {
    const parsed = pred.where orelse return false;
    const ctx = metric_ctx orelse return false;
    const measures: NodeMeasures = .{ .ctx = ctx, .match = match, .source = source };
    return expr.evaluate(parsed, measures);
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
    source: []const u8,
    metric_ctx: ?MetricContext,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(allocator, text),
            .placeholder => |p| try renderPlaceholder(allocator, &out, p, match, source, metric_ctx),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn renderPlaceholder(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    p: rule.Placeholder,
    match: ts.Query.Match,
    source: []const u8,
    metric_ctx: ?MetricContext,
) std.mem.Allocator.Error!void {
    if (p.measure == .text) {
        const text = findCaptureText(p.capture_id, match, source) orelse "?";
        return out.appendSlice(allocator, text);
    }
    const ctx = metric_ctx orelse return out.appendSlice(allocator, "?");
    const measures: NodeMeasures = .{ .ctx = ctx, .match = match, .source = source };
    const value = (try measures.measure(p.measure, p.capture_id)) orelse return out.appendSlice(allocator, "?");
    var buf: [10]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try out.appendSlice(allocator, rendered);
}

fn evalEq(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len != 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    const right_text = resolveText(pred.args[1], match, source) orelse return false;
    return std.mem.eql(u8, left_text, right_text) != negate;
}

fn evalAnyOf(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len < 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    for (pred.args[1..]) |arg| {
        const candidate = resolveText(arg, match, source) orelse continue;
        if (std.mem.eql(u8, left_text, candidate)) return !negate;
    }
    return negate;
}

fn evalMatch(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    const re = pred.regex orelse return false;
    const text = resolveText(pred.args[0], match, source) orelse return false;
    return re.isMatch(text) != negate;
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

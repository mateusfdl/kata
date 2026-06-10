const std = @import("std");
const ts = @import("tree_sitter");

const expr = @import("expr.zig");
const metric = @import("metric.zig");
const rule = @import("rule.zig");

pub const MetricContext = struct {
    allocator: std.mem.Allocator,
    compiled: *const metric.Compiled,
    cursor: *ts.QueryCursor,
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
            .where => if (!try evalWhere(pred, match, metric_ctx)) return false,
        }
    }
    return true;
}

fn evalWhere(
    pred: rule.Predicate,
    match: ts.Query.Match,
    metric_ctx: ?MetricContext,
) std.mem.Allocator.Error!bool {
    const parsed = pred.where orelse return false;
    const ctx = metric_ctx orelse return false;
    const measures: NodeMeasures = .{ .ctx = ctx, .match = match };
    return expr.evaluate(parsed, measures);
}

const NodeMeasures = struct {
    ctx: MetricContext,
    match: ts.Query.Match,

    pub const Error = std.mem.Allocator.Error;

    pub fn measure(self: NodeMeasures, m: expr.Measure, capture_id: u32) Error!?u32 {
        const node = findCaptureNode(capture_id, self.match) orelse return null;
        return switch (m) {
            .complexity => try metric.complexityOf(self.ctx.allocator, self.ctx.compiled, self.ctx.cursor, node),
            .nesting => try metric.nestingOf(self.ctx.allocator, self.ctx.compiled, self.ctx.cursor, node),
            .length => metric.lengthOf(node),
        };
    }
};

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

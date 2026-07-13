const std = @import("std");

const expr = @import("core").expr;
const glob = @import("core").glob;
const language = @import("core").language;
const metric = @import("metric.zig");
const query = @import("core").query;
const rule = @import("core").rule;
const Node = @import("core").node.Node;

pub const MetricContext = struct {
    allocator: std.mem.Allocator,
    compiled: *const metric.Compiled,
    lang: language.Name,
};

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    root: Node,
    metric: ?MetricContext = null,
};

pub fn evaluate(
    predicates: []const rule.Predicate,
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    for (predicates) |pred| {
        if (!try evalOne(pred, match, ctx)) return false;
    }
    return true;
}

fn evalOne(
    pred: rule.Predicate,
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    return switch (pred) {
        .eq => |args| evalEq(args, match, ctx.source, false),
        .not_eq => |args| evalEq(args, match, ctx.source, true),
        .any_of => |args| evalAnyOf(args, match, ctx.source, false),
        .not_any_of => |args| evalAnyOf(args, match, ctx.source, true),
        .match => |p| evalMatch(p, match, ctx.source, false),
        .not_match => |p| evalMatch(p, match, ctx.source, true),
        .starts_with => |args| evalStringHelper(args, match, ctx.source, .starts_with, false),
        .not_starts_with => |args| evalStringHelper(args, match, ctx.source, .starts_with, true),
        .ends_with => |args| evalStringHelper(args, match, ctx.source, .ends_with, false),
        .not_ends_with => |args| evalStringHelper(args, match, ctx.source, .ends_with, true),
        .contains => |args| evalStringHelper(args, match, ctx.source, .contains, false),
        .not_contains => |args| evalStringHelper(args, match, ctx.source, .contains, true),
        .glob => |args| evalStringHelper(args, match, ctx.source, .glob, false),
        .not_glob => |args| evalStringHelper(args, match, ctx.source, .glob, true),
        .captured => |args| evalCaptured(args, match, false),
        .not_captured => |args| evalCaptured(args, match, true),
        .where => |where| evalWhere(where, match, ctx),
        .has => |p| evalHas(p, match, ctx, false),
        .not_has => |p| evalHas(p, match, ctx, true),
        .inside => |p| evalInside(p, match, ctx, false),
        .not_inside => |p| evalInside(p, match, ctx, true),
        .parent => |p| evalParent(p, match, ctx, false),
        .not_parent => |p| evalParent(p, match, ctx, true),
        .count => |p| evalCount(p, match, ctx),
        .any_group => |members| evalAnyGroup(members, match, ctx),
        .all_group => |members| evaluate(members, match, ctx),
    };
}

fn evalAnyGroup(
    members: []const rule.Predicate,
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    for (members) |member| {
        if (try evalOne(member, match, ctx)) return true;
    }
    return false;
}

fn evalWhere(
    parsed: *const expr.Expr,
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const metric_ctx = ctx.metric orelse return false;
    const measures: NodeMeasures = .{ .ctx = metric_ctx, .match = match, .source = ctx.source };

    return expr.evaluate(parsed, measures);
}

fn evalHas(
    pred: rule.NestedPredicate,
    match: query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    const subject = subjectNode(pred.args, match) orelse return false;

    var sink: ExistentialSink = .{ .matcher = pred.matcher, .subject = subject, .ctx = ctx };
    try query.stream(ctx.allocator, &pred.matcher.pattern, pred.matcher.capture_count, subject, &sink);

    return sink.found != negate;
}

const ExistentialSink = struct {
    matcher: *const rule.NestedMatcher,
    subject: Node,
    ctx: EvalContext,
    found: bool = false,
    done: bool = false,

    pub fn emit(self: *ExistentialSink, bindings: []const ?Node) std.mem.Allocator.Error!void {
        if (!try nestedMatchPasses(self.matcher, .{ .nodes = bindings }, self.subject, self.ctx)) return;
        self.found = true;
        self.done = true;
    }
};

fn evalInside(
    pred: rule.NestedPredicate,
    match: query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    return evalEnclosing(pred, match, ctx, .ancestor, negate);
}

fn evalParent(
    pred: rule.NestedPredicate,
    match: query.Match,
    ctx: EvalContext,
    negate: bool,
) std.mem.Allocator.Error!bool {
    return evalEnclosing(pred, match, ctx, .direct_parent, negate);
}

fn evalEnclosing(
    pred: rule.NestedPredicate,
    match: query.Match,
    ctx: EvalContext,
    relation: EnclosingSink.Relation,
    negate: bool,
) std.mem.Allocator.Error!bool {
    const subject = subjectNode(pred.args, match) orelse return false;

    var sink: EnclosingSink = .{ .matcher = pred.matcher, .subject = subject, .ctx = ctx, .relation = relation, .until_kinds = pred.until_kinds };
    try query.stream(ctx.allocator, &pred.matcher.pattern, pred.matcher.capture_count, ctx.root, &sink);

    return sink.found != negate;
}

const EnclosingSink = struct {
    matcher: *const rule.NestedMatcher,
    subject: Node,
    ctx: EvalContext,
    relation: Relation,
    until_kinds: []const u16 = &.{},
    found: bool = false,
    done: bool = false,

    const Relation = enum { ancestor, direct_parent };

    pub fn emit(self: *EnclosingSink, bindings: []const ?Node) std.mem.Allocator.Error!void {
        const nested_match: query.Match = .{ .nodes = bindings };
        const candidate = nested_match.get(self.matcher.root_capture_id) orelse return;
        const related = switch (self.relation) {
            .ancestor => strictlyContains(candidate, self.subject),
            .direct_parent => isDirectParent(candidate, self.subject),
        };
        if (!related) return;
        if (self.relation == .ancestor and crossesBoundary(self.subject, candidate, self.until_kinds)) return;
        if (!try evaluate(self.matcher.predicates, nested_match, self.ctx)) return;
        self.found = true;
        self.done = true;
    }
};

fn crossesBoundary(subject: Node, candidate: Node, until_kinds: []const u16) bool {
    if (until_kinds.len == 0) return false;
    var current = subject.parent();
    while (current) |node| : (current = node.parent()) {
        if (node.eql(candidate)) return false;
        if (std.mem.indexOfScalar(u16, until_kinds, node.kindId()) != null) return true;
    }
    return false;
}

fn isDirectParent(candidate: Node, subject: Node) bool {
    const p = subject.parent() orelse return false;
    return p.eql(candidate);
}

fn evalCount(
    pred: rule.CountPredicate,
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const subject = subjectNode(pred.args, match) orelse return false;

    var sink: CountingSink = .{ .matcher = pred.matcher, .subject = subject, .ctx = ctx };
    try query.stream(ctx.allocator, &pred.matcher.pattern, pred.matcher.capture_count, subject, &sink);

    return compareCount(pred.compare.op, sink.total, pred.compare.value);
}

const CountingSink = struct {
    matcher: *const rule.NestedMatcher,
    subject: Node,
    ctx: EvalContext,
    total: u32 = 0,
    done: bool = false,

    pub fn emit(self: *CountingSink, bindings: []const ?Node) std.mem.Allocator.Error!void {
        if (try nestedMatchPasses(self.matcher, .{ .nodes = bindings }, self.subject, self.ctx)) self.total += 1;
    }
};

fn nestedMatchPasses(
    nested: *const rule.NestedMatcher,
    nested_match: query.Match,
    subject: Node,
    ctx: EvalContext,
) std.mem.Allocator.Error!bool {
    const root_node = nested_match.get(nested.root_capture_id) orelse return false;
    if (sameRange(root_node, subject)) return false;

    return evaluate(nested.predicates, nested_match, ctx);
}

fn subjectNode(args: []const rule.PredicateOperand, match: query.Match) ?Node {
    if (args.len != 1) return null;

    return switch (args[0]) {
        .capture => |id| match.get(id),
        .string => null,
    };
}

fn strictlyContains(enclosing: Node, node: Node) bool {
    if (sameRange(enclosing, node)) return false;

    return enclosing.startByte() <= node.startByte() and node.endByte() <= enclosing.endByte();
}

fn sameRange(a: Node, b: Node) bool {
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
    match: query.Match,
    source: []const u8,

    pub const Error = std.mem.Allocator.Error;

    pub fn measure(self: NodeMeasures, m: expr.Measure, capture_id: query.CaptureId) Error!?u32 {
        const node = self.match.get(capture_id) orelse return null;

        return switch (m) {
            .complexity => try metric.complexityOf(self.ctx.allocator, self.ctx.compiled, node),
            .nesting => try metric.nestingOf(self.ctx.allocator, self.ctx.compiled, node),
            .length => metric.lengthOf(node),
            .text => self.numericText(node),
            .params => metric.paramsOf(node, self.ctx.lang),
            .args => metric.argsOf(node),
            .position => metric.positionOf(node),
            .siblings => metric.siblingsOf(node),
        };
    }

    fn numericText(self: NodeMeasures, node: Node) ?u32 {
        const text = node.text(self.source) orelse return null;

        return std.fmt.parseInt(u32, text, 10) catch null;
    }
};

pub fn renderMessage(
    allocator: std.mem.Allocator,
    segments: []const rule.MessageSegment,
    match: query.Match,
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
    match: query.Match,
    ctx: EvalContext,
) std.mem.Allocator.Error!void {
    if (p.measure == .text) {
        const text = captureText(p.capture_id, match, ctx.source) orelse "?";

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
    match: query.Match,
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
    match: query.Match,
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

fn evalCaptured(args: []const rule.PredicateOperand, match: query.Match, negate: bool) bool {
    if (args.len != 1) return false;

    const present = switch (args[0]) {
        .capture => |id| match.get(id) != null,
        .string => false,
    };

    return present != negate;
}

const StringHelper = enum { starts_with, ends_with, contains, glob };

fn evalStringHelper(
    args: []const rule.PredicateOperand,
    match: query.Match,
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
    match: query.Match,
    source: []const u8,
    negate: bool,
) bool {
    const text = resolveText(pred.args[0], match, source) orelse return false;

    return pred.regex.isMatch(text) != negate;
}

fn resolveText(
    operand: rule.PredicateOperand,
    match: query.Match,
    source: []const u8,
) ?[]const u8 {
    return switch (operand) {
        .string => |s| s,
        .capture => |id| captureText(id, match, source),
    };
}

fn captureText(
    id: query.CaptureId,
    match: query.Match,
    source: []const u8,
) ?[]const u8 {
    const node = match.get(id) orelse return null;

    return node.text(source);
}

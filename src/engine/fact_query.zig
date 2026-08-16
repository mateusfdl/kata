const std = @import("std");
const mvzr = @import("mvzr");

const facts = @import("facts.zig");
const fact_schema = @import("fact_schema.zig");
const glob = @import("glob.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

const fieldValue = fact_schema.fieldValue;

pub const CaptureId = usize;
pub const CaptureSet = u64;

fn captureBit(capture: CaptureId) CaptureSet {
    return @as(CaptureSet, 1) << @intCast(capture);
}

pub const FieldOperand = struct {
    capture: CaptureId,
    field: fact_schema.Field,
};

pub const HelperOperand = struct {
    id: fact_schema.HelperId,
    capture: CaptureId,
};

pub const Operand = union(enum) {
    field: FieldOperand,
    literal: []const u8,
    helper: HelperOperand,
};

pub const Op = enum {
    eq,
    not_eq,
    any_of,
    not_any_of,
    match,
    not_match,
    starts_with,
    not_starts_with,
    ends_with,
    not_ends_with,
    contains,
    not_contains,
    glob,
    not_glob,
};

pub const ScalarPredicate = struct {
    op: Op,
    args: []const Operand,
    regex: ?mvzr.Regex = null,
    requires: CaptureSet = 0,
};

pub const FactQuery = struct {
    fact: fact_schema.FactKind,
    capture: CaptureId,
    predicates: []const Predicate,
    requires: CaptureSet = 0,
};

pub const CountCompare = enum {
    gt,
    ge,
    lt,
    le,
    eq,
    ne,
};

pub const CountPredicate = struct {
    query: FactQuery,
    op: CountCompare,
    value: u32,
};

pub const Group = struct {
    requires: CaptureSet = 0,
    members: []const Predicate,
};

pub const Predicate = union(enum) {
    scalar: ScalarPredicate,
    all_group: Group,
    any_group: Group,
    exists: FactQuery,
    not_exists: FactQuery,
    count: CountPredicate,
};

pub const Truth = enum {
    no,
    yes,
    unknown,

    fn negate(self: Truth) Truth {
        return switch (self) {
            .no => .yes,
            .yes => .no,
            .unknown => .unknown,
        };
    }

    fn conjoin(self: Truth, other: Truth) Truth {
        if (self == .no or other == .no) return .no;
        if (self == .unknown or other == .unknown) return .unknown;

        return .yes;
    }
};

pub const BoundFact = struct {
    fact: fact_schema.Fact,
    file: *const facts.FileFacts,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    index: *const ProjectIndex,
    class_names: *const std.StringHashMapUnmanaged(void),
};

pub fn evaluate(predicates: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    var result: Truth = .yes;
    for (predicates) |pred| {
        const current = try evalPredicate(pred, ctx, bindings);
        if (current == .no) return .no;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

fn predicateRequires(predicate: Predicate) CaptureSet {
    return switch (predicate) {
        .scalar => |scalar| scalar.requires,
        .all_group, .any_group => |group| group.requires,
        .exists, .not_exists => |query| query.requires,
        .count => |count| count.query.requires,
    };
}

fn evaluatePartition(predicates: []const Predicate, ctx: Context, bindings: []?BoundFact, capture: CaptureId, comptime candidate_dependent: bool) std.mem.Allocator.Error!Truth {
    var result: Truth = .yes;
    for (predicates) |pred| {
        const needs_candidate = predicateRequires(pred) & captureBit(capture) != 0;
        if (needs_candidate != candidate_dependent) continue;
        const current = try evalPredicate(pred, ctx, bindings);
        if (current == .no) return .no;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

fn evalPredicate(pred: Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    return switch (pred) {
        .scalar => |scalar| evalScalar(scalar, ctx, bindings),
        .all_group => |group| evaluate(group.members, ctx, bindings),
        .any_group => |group| evalAnyGroup(group.members, ctx, bindings),
        .exists => |query| evalExists(query, ctx, bindings),
        .not_exists => |query| (try evalExists(query, ctx, bindings)).negate(),
        .count => |count| evalCount(count, ctx, bindings),
    };
}

fn evalAnyGroup(members: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    var result: Truth = .no;
    for (members) |member| {
        const current = try evalPredicate(member, ctx, bindings);
        if (current == .yes) return .yes;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

fn evalScalar(pred: ScalarPredicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    return switch (pred.op) {
        .eq => evalEq(pred, ctx, bindings, false),
        .not_eq => evalEq(pred, ctx, bindings, true),
        .any_of => evalAnyOf(pred, ctx, bindings, false),
        .not_any_of => evalAnyOf(pred, ctx, bindings, true),
        .match => evalMatch(pred, ctx, bindings, false),
        .not_match => evalMatch(pred, ctx, bindings, true),
        .starts_with => evalStringHelper(pred, ctx, bindings, .starts_with, false),
        .not_starts_with => evalStringHelper(pred, ctx, bindings, .starts_with, true),
        .ends_with => evalStringHelper(pred, ctx, bindings, .ends_with, false),
        .not_ends_with => evalStringHelper(pred, ctx, bindings, .ends_with, true),
        .contains => evalStringHelper(pred, ctx, bindings, .contains, false),
        .not_contains => evalStringHelper(pred, ctx, bindings, .contains, true),
        .glob => evalStringHelper(pred, ctx, bindings, .glob, false),
        .not_glob => evalStringHelper(pred, ctx, bindings, .glob, true),
    };
}

fn evalEq(pred: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
    if (pred.args.len != 2) return .no;

    const left = (try resolveOperand(pred.args[0], ctx, bindings)) orelse return .unknown;
    const right = (try resolveOperand(pred.args[1], ctx, bindings)) orelse return .unknown;

    return if (std.mem.eql(u8, left, right) != negate) .yes else .no;
}

fn evalAnyOf(pred: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
    if (pred.args.len < 2) return .no;

    const left = (try resolveOperand(pred.args[0], ctx, bindings)) orelse return .unknown;
    var unknown = false;
    for (pred.args[1..]) |arg| {
        const candidate = (try resolveOperand(arg, ctx, bindings)) orelse {
            unknown = true;
            continue;
        };
        if (std.mem.eql(u8, left, candidate)) return if (negate) .no else .yes;
    }

    if (unknown) return .unknown;
    return if (negate) .yes else .no;
}

fn evalMatch(pred: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
    const re = pred.regex orelse return .no;
    if (pred.args.len != 1) return .no;

    const text = (try resolveOperand(pred.args[0], ctx, bindings)) orelse return .unknown;

    return if (re.isMatch(text) != negate) .yes else .no;
}

const StringHelper = enum { starts_with, ends_with, contains, glob };

fn evalStringHelper(
    pred: ScalarPredicate,
    ctx: Context,
    bindings: []?BoundFact,
    helper: StringHelper,
    negate: bool,
) std.mem.Allocator.Error!Truth {
    if (pred.args.len != 2) return .no;

    const subject = (try resolveOperand(pred.args[0], ctx, bindings)) orelse return .unknown;
    const candidate = (try resolveOperand(pred.args[1], ctx, bindings)) orelse return .unknown;
    const found = switch (helper) {
        .starts_with => std.mem.startsWith(u8, subject, candidate),
        .ends_with => std.mem.endsWith(u8, subject, candidate),
        .contains => std.mem.indexOf(u8, subject, candidate) != null,
        .glob => glob.match(candidate, subject),
    };

    return if (found != negate) .yes else .no;
}

const QueryScanControl = fact_schema.VisitControl;

const ExistsSink = struct {
    ctx: Context,
    query: FactQuery,
    bindings: []?BoundFact,
    outer: Truth,
    result: Truth = .no,
    visited: bool = false,

    pub fn visit(self: *ExistsSink, file: *const facts.FileFacts, fact: fact_schema.Fact) std.mem.Allocator.Error!QueryScanControl {
        self.visited = true;
        self.bindings[self.query.capture] = .{ .fact = fact, .file = file };
        defer self.bindings[self.query.capture] = null;

        const result = self.outer.conjoin(try evaluatePartition(self.query.predicates, self.ctx, self.bindings, self.query.capture, true));
        if (result == .yes) {
            self.result = .yes;
            return .stop;
        }
        if (result == .unknown) self.result = .unknown;

        return .continue_scan;
    }
};

const CountSink = struct {
    ctx: Context,
    query: FactQuery,
    bindings: []?BoundFact,
    outer: Truth,
    total: u32 = 0,
    unknown: u32 = 0,
    visited: bool = false,

    pub fn visit(self: *CountSink, file: *const facts.FileFacts, fact: fact_schema.Fact) std.mem.Allocator.Error!QueryScanControl {
        self.visited = true;
        self.bindings[self.query.capture] = .{ .fact = fact, .file = file };
        defer self.bindings[self.query.capture] = null;

        switch (self.outer.conjoin(try evaluatePartition(self.query.predicates, self.ctx, self.bindings, self.query.capture, true))) {
            .yes => self.total +|= 1,
            .unknown => self.unknown +|= 1,
            .no => {},
        }

        return .continue_scan;
    }
};

fn evalExists(query: FactQuery, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    const outer = try evaluatePartition(query.predicates, ctx, bindings, query.capture, false);
    if (outer == .no) return .no;

    var sink: ExistsSink = .{ .ctx = ctx, .query = query, .bindings = bindings, .outer = outer };
    try scanQuery(ctx, query, &sink);
    if (!sink.visited and try hasUnknownBoundOperand(query.requires, query.predicates, ctx, bindings)) return .unknown;

    return sink.result;
}

fn evalCount(count: CountPredicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    const outer = try evaluatePartition(count.query.predicates, ctx, bindings, count.query.capture, false);

    var sink: CountSink = .{ .ctx = ctx, .query = count.query, .bindings = bindings, .outer = outer };
    if (outer != .no) {
        try scanQuery(ctx, count.query, &sink);
        if (!sink.visited and try hasUnknownBoundOperand(count.query.requires, count.query.predicates, ctx, bindings)) return .unknown;
    }

    const minimum = sink.total;
    const maximum = sink.total +| sink.unknown;
    return switch (count.op) {
        .gt => if (minimum > count.value) .yes else if (maximum <= count.value) .no else .unknown,
        .ge => if (minimum >= count.value) .yes else if (maximum < count.value) .no else .unknown,
        .lt => if (maximum < count.value) .yes else if (minimum >= count.value) .no else .unknown,
        .le => if (maximum <= count.value) .yes else if (minimum > count.value) .no else .unknown,
        .eq => if (minimum == maximum and minimum == count.value) .yes else if (count.value < minimum or count.value > maximum) .no else .unknown,
        .ne => if (count.value < minimum or count.value > maximum) .yes else if (minimum == maximum and minimum == count.value) .no else .unknown,
    };
}

fn hasUnknownBoundOperand(requires: CaptureSet, predicates: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .scalar => |scalar| for (scalar.args) |operand| {
                const capture = operandCapture(operand) orelse continue;
                if (requires & captureBit(capture) == 0) continue;
                if (try resolveOperand(operand, ctx, bindings) == null) return true;
            },
            .all_group, .any_group => |group| if (try hasUnknownBoundOperand(requires, group.members, ctx, bindings)) return true,
            .exists, .not_exists => |query| if (try hasUnknownBoundOperand(requires, query.predicates, ctx, bindings)) return true,
            .count => |count| if (try hasUnknownBoundOperand(requires, count.query.predicates, ctx, bindings)) return true,
        }
    }

    return false;
}

fn operandCapture(operand: Operand) ?CaptureId {
    return switch (operand) {
        .literal => null,
        .field => |field| field.capture,
        .helper => |helper| helper.capture,
    };
}

fn scanQuery(ctx: Context, query: FactQuery, sink: anytype) std.mem.Allocator.Error!void {
    _ = try ctx.index.scan(query.fact, sink);
}

pub fn resolveOperand(operand: Operand, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!?[]const u8 {
    return switch (operand) {
        .literal => |s| s,
        .field => |field| if (bound(bindings, field.capture)) |fact| fieldValue(fact.fact, field.field, fact.file) else null,
        .helper => |helper| if (bound(bindings, helper.capture)) |fact| switch (helper.id) {
            .receiver_type => receiverType(ctx, fact),
            .resolved_import_source => try resolvedImportSource(ctx, fact),
        } else null,
    };
}

fn bound(bindings: []?BoundFact, capture: CaptureId) ?BoundFact {
    if (capture >= bindings.len) return null;

    return bindings[capture];
}

fn receiverType(ctx: Context, bound_fact: BoundFact) ?[]const u8 {
    const call = switch (bound_fact.fact) {
        .call => |c| c,
        else => return null,
    };
    const resolved = facts.receiverType(bound_fact.file, call.receiver) orelse return null;
    if (!ctx.class_names.contains(resolved)) return null;

    return resolved;
}

fn resolvedImportSource(ctx: Context, bound_fact: BoundFact) std.mem.Allocator.Error!?[]const u8 {
    const im = switch (bound_fact.fact) {
        .import => |i| i,
        else => return null,
    };

    return facts.resolveImportSource(ctx.allocator, bound_fact.file.lang.family(), bound_fact.file.path, im.source);
}

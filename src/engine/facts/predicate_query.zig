const std = @import("std");

const context_query = @import("context_query.zig");
const count_query = @import("count_query.zig");
const fact_query = @import("fact_query.zig");
const scalar_query = @import("scalar_query.zig");
const truth_query = @import("truth_query.zig");

const BoundFact = context_query.BoundFact;
const CaptureId = context_query.CaptureId;
const CaptureSet = context_query.CaptureSet;
const Context = context_query.Context;
const Truth = truth_query.Truth;

pub const Group = struct {
    requires: CaptureSet = 0,
    members: []const Predicate,
};

pub const Predicate = union(enum) {
    scalar: scalar_query.ScalarPredicate,
    all_group: Group,
    any_group: Group,
    exists: fact_query.FactQuery,
    not_exists: fact_query.FactQuery,
    count: count_query.CountPredicate,

    pub fn eval(self: Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
        return switch (self) {
            .scalar => |scalar| scalar.eval(ctx, bindings),
            .all_group => |group| evaluate(group.members, ctx, bindings),
            .any_group => |group| evalAnyGroup(group.members, ctx, bindings),
            .exists => |query| query.exists(ctx, bindings),
            .not_exists => |query| (try query.exists(ctx, bindings)).negate(),
            .count => |count| count.eval(ctx, bindings),
        };
    }

    pub fn requires(self: Predicate) CaptureSet {
        return switch (self) {
            .scalar => |scalar| scalar.requires,
            .all_group, .any_group => |group| group.requires,
            .exists, .not_exists => |query| query.requires,
            .count => |count| count.query.requires,
        };
    }
};

pub fn evaluate(predicates: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    var result: Truth = .yes;
    for (predicates) |pred| {
        const current = try pred.eval(ctx, bindings);
        if (current == .no) return .no;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

pub fn evaluatePartition(predicates: []const Predicate, ctx: Context, bindings: []?BoundFact, capture: CaptureId, comptime candidate_dependent: bool) std.mem.Allocator.Error!Truth {
    var result: Truth = .yes;
    for (predicates) |pred| {
        const needs_candidate = pred.requires() & captureBit(capture) != 0;
        if (needs_candidate != candidate_dependent) continue;
        const current = try pred.eval(ctx, bindings);
        if (current == .no) return .no;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

pub fn hasUnknownBoundOperand(requires: CaptureSet, predicates: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .scalar => |scalar| for (scalar.args) |operand| {
                const capture = operand.captureId() orelse continue;
                if (requires & captureBit(capture) == 0) continue;
                if (try operand.resolve(ctx, bindings) == null) return true;
            },
            .all_group, .any_group => |group| if (try hasUnknownBoundOperand(requires, group.members, ctx, bindings)) return true,
            .exists, .not_exists => |query| if (try hasUnknownBoundOperand(requires, query.predicates, ctx, bindings)) return true,
            .count => |count| if (try hasUnknownBoundOperand(requires, count.query.predicates, ctx, bindings)) return true,
        }
    }

    return false;
}

fn evalAnyGroup(members: []const Predicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
    var result: Truth = .no;
    for (members) |member| {
        const current = try member.eval(ctx, bindings);
        if (current == .yes) return .yes;
        if (current == .unknown) result = .unknown;
    }

    return result;
}

fn captureBit(capture: CaptureId) CaptureSet {
    return @as(CaptureSet, 1) << @intCast(capture);
}

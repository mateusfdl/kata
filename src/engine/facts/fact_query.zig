const std = @import("std");

const context_query = @import("context_query.zig");
const facts = @import("../facts.zig");
const fact_schema = @import("../fact_schema.zig");
const predicate_query = @import("predicate_query.zig");
const truth_query = @import("truth_query.zig");

const BoundFact = context_query.BoundFact;
const CaptureId = context_query.CaptureId;
const CaptureSet = context_query.CaptureSet;
const Context = context_query.Context;
const Predicate = predicate_query.Predicate;
const Truth = truth_query.Truth;

pub const FactQuery = struct {
    fact: fact_schema.FactKind,
    capture: CaptureId,
    predicates: []const Predicate,
    requires: CaptureSet = 0,

    pub fn exists(self: FactQuery, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
        const outer = try predicate_query.evaluatePartition(self.predicates, ctx, bindings, self.capture, false);
        if (outer == .no) return .no;

        var sink: ExistsSink = .{ .ctx = ctx, .query = self, .bindings = bindings, .outer = outer };
        try self.scan(ctx, &sink);
        if (!sink.visited and try predicate_query.hasUnknownBoundOperand(self.requires, self.predicates, ctx, bindings)) return .unknown;

        return sink.result;
    }

    pub fn scan(self: FactQuery, ctx: Context, sink: anytype) std.mem.Allocator.Error!void {
        _ = try ctx.index.scan(self.fact, sink);
    }
};

const ExistsSink = struct {
    ctx: Context,
    query: FactQuery,
    bindings: []?BoundFact,
    outer: Truth,
    result: Truth = .no,
    visited: bool = false,

    pub fn visit(self: *ExistsSink, file: *const facts.FileFacts, fact: fact_schema.Fact) std.mem.Allocator.Error!fact_schema.VisitControl {
        self.visited = true;
        self.bindings[self.query.capture] = .{ .fact = fact, .file = file };
        defer self.bindings[self.query.capture] = null;

        const result = self.outer.conjoin(try predicate_query.evaluatePartition(self.query.predicates, self.ctx, self.bindings, self.query.capture, true));
        if (result == .yes) {
            self.result = .yes;
            return .stop;
        }
        if (result == .unknown) self.result = .unknown;

        return .continue_scan;
    }
};

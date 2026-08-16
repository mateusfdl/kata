const std = @import("std");

const context_query = @import("context_query.zig");
const facts = @import("../facts.zig");
const fact_query = @import("fact_query.zig");
const fact_schema = @import("../fact_schema.zig");
const predicate_query = @import("predicate_query.zig");
const truth_query = @import("truth_query.zig");

const BoundFact = context_query.BoundFact;
const Context = context_query.Context;
const FactQuery = fact_query.FactQuery;
const Truth = truth_query.Truth;

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

    pub fn eval(self: CountPredicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
        const outer = try predicate_query.evaluatePartition(self.query.predicates, ctx, bindings, self.query.capture, false);

        var sink: CountSink = .{ .ctx = ctx, .query = self.query, .bindings = bindings, .outer = outer };
        if (outer != .no) {
            try self.query.scan(ctx, &sink);
            if (!sink.visited and try predicate_query.hasUnknownBoundOperand(self.query.requires, self.query.predicates, ctx, bindings)) return .unknown;
        }

        const minimum = sink.total;
        const maximum = sink.total +| sink.unknown;
        return switch (self.op) {
            .gt => if (minimum > self.value) .yes else if (maximum <= self.value) .no else .unknown,
            .ge => if (minimum >= self.value) .yes else if (maximum < self.value) .no else .unknown,
            .lt => if (maximum < self.value) .yes else if (minimum >= self.value) .no else .unknown,
            .le => if (maximum <= self.value) .yes else if (minimum > self.value) .no else .unknown,
            .eq => if (minimum == maximum and minimum == self.value) .yes else if (self.value < minimum or self.value > maximum) .no else .unknown,
            .ne => if (self.value < minimum or self.value > maximum) .yes else if (minimum == maximum and minimum == self.value) .no else .unknown,
        };
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

    pub fn visit(self: *CountSink, file: *const facts.FileFacts, fact: fact_schema.Fact) std.mem.Allocator.Error!fact_schema.VisitControl {
        self.visited = true;
        self.bindings[self.query.capture] = .{ .fact = fact, .file = file };
        defer self.bindings[self.query.capture] = null;

        switch (self.outer.conjoin(try predicate_query.evaluatePartition(self.query.predicates, self.ctx, self.bindings, self.query.capture, true))) {
            .yes => self.total +|= 1,
            .unknown => self.unknown +|= 1,
            .no => {},
        }

        return .continue_scan;
    }
};

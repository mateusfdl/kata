const std = @import("std");
const mvzr = @import("mvzr");

const context_query = @import("context_query.zig");
const glob = @import("../glob.zig");
const operand_query = @import("operand_query.zig");
const truth_query = @import("truth_query.zig");

const BoundFact = context_query.BoundFact;
const CaptureSet = context_query.CaptureSet;
const Context = context_query.Context;
const Operand = operand_query.Operand;
const Truth = truth_query.Truth;

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

    pub fn eval(self: ScalarPredicate, ctx: Context, bindings: []?BoundFact) std.mem.Allocator.Error!Truth {
        return switch (self.op) {
            .eq => self.evalEq(ctx, bindings, false),
            .not_eq => self.evalEq(ctx, bindings, true),
            .any_of => self.evalAnyOf(ctx, bindings, false),
            .not_any_of => self.evalAnyOf(ctx, bindings, true),
            .match => self.evalMatch(ctx, bindings, false),
            .not_match => self.evalMatch(ctx, bindings, true),
            .starts_with => self.evalStringHelper(ctx, bindings, .starts_with, false),
            .not_starts_with => self.evalStringHelper(ctx, bindings, .starts_with, true),
            .ends_with => self.evalStringHelper(ctx, bindings, .ends_with, false),
            .not_ends_with => self.evalStringHelper(ctx, bindings, .ends_with, true),
            .contains => self.evalStringHelper(ctx, bindings, .contains, false),
            .not_contains => self.evalStringHelper(ctx, bindings, .contains, true),
            .glob => self.evalStringHelper(ctx, bindings, .glob, false),
            .not_glob => self.evalStringHelper(ctx, bindings, .glob, true),
        };
    }

    fn evalEq(self: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
        if (self.args.len != 2) return .no;

        const left = (try self.args[0].resolve(ctx, bindings)) orelse return .unknown;
        const right = (try self.args[1].resolve(ctx, bindings)) orelse return .unknown;

        return if (std.mem.eql(u8, left, right) != negate) .yes else .no;
    }

    fn evalAnyOf(self: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
        if (self.args.len < 2) return .no;

        const left = (try self.args[0].resolve(ctx, bindings)) orelse return .unknown;
        var unknown = false;
        for (self.args[1..]) |arg| {
            const candidate = (try arg.resolve(ctx, bindings)) orelse {
                unknown = true;
                continue;
            };
            if (std.mem.eql(u8, left, candidate)) return if (negate) .no else .yes;
        }

        if (unknown) return .unknown;
        return if (negate) .yes else .no;
    }

    fn evalMatch(self: ScalarPredicate, ctx: Context, bindings: []?BoundFact, negate: bool) std.mem.Allocator.Error!Truth {
        const re = self.regex orelse return .no;
        if (self.args.len != 1) return .no;

        const text = (try self.args[0].resolve(ctx, bindings)) orelse return .unknown;

        return if (re.isMatch(text) != negate) .yes else .no;
    }

    fn evalStringHelper(
        self: ScalarPredicate,
        ctx: Context,
        bindings: []?BoundFact,
        helper: StringHelper,
        negate: bool,
    ) std.mem.Allocator.Error!Truth {
        if (self.args.len != 2) return .no;

        const subject = (try self.args[0].resolve(ctx, bindings)) orelse return .unknown;
        const candidate = (try self.args[1].resolve(ctx, bindings)) orelse return .unknown;
        const found = switch (helper) {
            .starts_with => std.mem.startsWith(u8, subject, candidate),
            .ends_with => std.mem.endsWith(u8, subject, candidate),
            .contains => std.mem.indexOf(u8, subject, candidate) != null,
            .glob => glob.match(candidate, subject),
        };

        return if (found != negate) .yes else .no;
    }
};

const StringHelper = enum { starts_with, ends_with, contains, glob };

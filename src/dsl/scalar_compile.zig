const std = @import("std");
const mvzr = @import("mvzr");

const ast = @import("ast.zig");
const bytes = @import("bytes.zig");
const tokenizer = @import("tokenizer.zig");

pub const Operation = enum {
    eq,
    not_eq,
    any_of,
    not_any_of,
    starts_with,
    not_starts_with,
    ends_with,
    not_ends_with,
    contains,
    not_contains,
    glob,
    not_glob,
};

const CallKind = enum {
    matches,
    glob,
    any_of,
    none_of,
    starts_with,
    ends_with,
    contains,
};

const call_dispatch = std.StaticStringMap(CallKind).initComptime(.{
    .{ bytes.call_matches, .matches },
    .{ bytes.call_glob, .glob },
    .{ bytes.call_any_of, .any_of },
    .{ bytes.call_none_of, .none_of },
    .{ bytes.call_starts_with, .starts_with },
    .{ bytes.call_ends_with, .ends_with },
    .{ bytes.call_contains, .contains },
});

pub fn ScalarCompiler(comptime Adapter: type) type {
    return struct {
        const Context = Adapter.Context;
        const Error = Adapter.Error;
        const Operand = Adapter.Operand;
        const Predicate = Adapter.Predicate;
        const Self = @This();

        pub fn predicateFrom(ctx: *Context, expression: ast.Expression, negated: bool) Error!?Predicate {
            return switch (expression) {
                .negate => |negate| Self.predicateFrom(ctx, negate.expression.*, !negated),
                .call => |call| callPredicate(ctx, call, negated),
                .compare => |compare| comparePredicate(ctx, compare, negated),
                .logical => |logical| if (logical.op == .@"or") anyOfPredicate(ctx, expression, negated) else null,
                .membership => |membership| membershipPredicate(ctx, membership, negated),
                else => null,
            };
        }

        fn membershipPredicate(ctx: *Context, membership: ast.Membership, negated: bool) Error!?Predicate {
            const detail = Adapter.membership_detail;
            const subject = (try Adapter.textOperand(ctx, membership.subject.*)) orelse
                return Adapter.failWith(ctx, detail, membership.range);
            if (!Adapter.isAnyOfSubject(subject)) return Adapter.failWith(ctx, detail, membership.range);

            const args = try Adapter.allocator(ctx).alloc(Operand, membership.values.len + 1);
            args[0] = subject;
            for (membership.values, args[1..]) |value, *slot| {
                slot.* = try Adapter.literalOperand(ctx, value.value);
            }

            const effective = membership.negated != negated;
            return Adapter.emit(if (effective) .not_any_of else .any_of, args);
        }

        fn callPredicate(ctx: *Context, call: ast.Call, negated: bool) Error!?Predicate {
            if (call_dispatch.get(call.name)) |kind| {
                return switch (kind) {
                    .matches => matchesPredicate(ctx, call, negated),
                    .glob => globPredicate(ctx, call, negated),
                    .any_of => anyOfHelperPredicate(ctx, call, negated),
                    .none_of => anyOfHelperPredicate(ctx, call, !negated),
                    .starts_with => stringHelperPredicate(ctx, call, negated, .starts_with, .not_starts_with),
                    .ends_with => stringHelperPredicate(ctx, call, negated, .ends_with, .not_ends_with),
                    .contains => stringHelperPredicate(ctx, call, negated, .contains, .not_contains),
                };
            }

            const handler = Adapter.extra_call_dispatch.get(call.name) orelse return null;
            return handler(ctx, call, negated);
        }

        fn anyOfHelperPredicate(ctx: *Context, call: ast.Call, negated: bool) Error!?Predicate {
            const detail = Adapter.any_of_detail;
            if (call.args.len < 2) return Adapter.failWith(ctx, detail, call.range);

            const subject = (try Adapter.textOperand(ctx, call.args[0])) orelse
                return Adapter.failWith(ctx, detail, call.range);
            if (!Adapter.isAnyOfSubject(subject)) return Adapter.failWith(ctx, detail, call.range);

            const args = try Adapter.allocator(ctx).alloc(Operand, call.args.len);
            args[0] = subject;
            for (call.args[1..], args[1..]) |arg, *slot| {
                if (arg != .string) return Adapter.failWith(ctx, detail, call.range);
                slot.* = try Adapter.literalOperand(ctx, arg.string.value);
            }

            return Adapter.emit(if (negated) .not_any_of else .any_of, args);
        }

        fn stringHelperPredicate(
            ctx: *Context,
            call: ast.Call,
            negated: bool,
            positive: Operation,
            negative: Operation,
        ) Error!?Predicate {
            const args = try stringHelperArgs(ctx, call);
            return Adapter.emit(if (negated) negative else positive, args);
        }

        fn stringHelperArgs(ctx: *Context, call: ast.Call) Error![]Operand {
            const detail = "startsWith, endsWith, and contains expect (value, text)";
            if (call.args.len != 2) return Adapter.failWith(ctx, detail, call.range);
            const subject = (try Adapter.textOperand(ctx, call.args[0])) orelse
                return Adapter.failWith(ctx, detail, call.range);
            const candidate = (try Adapter.textOperand(ctx, call.args[1])) orelse
                return Adapter.failWith(ctx, detail, call.range);
            const args = try Adapter.allocator(ctx).alloc(Operand, 2);
            args[0] = subject;
            args[1] = candidate;
            return args;
        }

        fn matchesPredicate(ctx: *Context, call: ast.Call, negated: bool) Error!?Predicate {
            if (call.args.len != 2) return Adapter.failWith(ctx, "matches expects (value, regex)", call.range);

            const subject = (try Adapter.textOperand(ctx, call.args[0])) orelse
                return Adapter.failWith(ctx, "matches expects a text value", call.range);
            const pattern = switch (call.args[1]) {
                .string => |string| try Adapter.allocator(ctx).dupe(u8, string.value),
                else => return Adapter.failWith(ctx, "matches expects a string regex", call.range),
            };
            const regex = mvzr.compile(pattern) orelse {
                Adapter.report(ctx, "invalid regex", call.range);
                return error.InvalidRegex;
            };

            return try Adapter.emitRegex(ctx, subject, pattern, regex, negated);
        }

        fn globPredicate(ctx: *Context, call: ast.Call, negated: bool) Error!?Predicate {
            const detail = "glob expects (value, \"pattern\")";
            if (call.args.len != 2 or call.args[1] != .string) return Adapter.failWith(ctx, detail, call.range);

            const subject = (try Adapter.textOperand(ctx, call.args[0])) orelse
                return Adapter.failWith(ctx, detail, call.range);
            const args = try Adapter.allocator(ctx).alloc(Operand, 2);
            args[0] = subject;
            args[1] = try Adapter.literalOperand(ctx, call.args[1].string.value);

            return Adapter.emit(if (negated) .not_glob else .glob, args);
        }

        fn comparePredicate(ctx: *Context, compare: ast.Compare, negated: bool) Error!?Predicate {
            const left = try Adapter.textOperand(ctx, compare.left.*);
            const right = try Adapter.textOperand(ctx, compare.right.*);

            if (compare.op == .eq or compare.op == .ne) {
                const resolved_left = left orelse return null;
                const resolved_right = right orelse return null;
                const wants_eq = (compare.op == .eq) != negated;
                const args = try Adapter.allocator(ctx).alloc(Operand, 2);
                args[0] = resolved_left;
                args[1] = resolved_right;

                return Adapter.emit(if (wants_eq) .eq else .not_eq, args);
            }

            const reject = if (Adapter.compare_has_numeric_fallback)
                left != null and right != null
            else
                left != null or right != null;
            if (reject) {
                Adapter.report(ctx, "strings compare with == and != only", compare.range);
                return error.InvalidStringComparison;
            }

            return null;
        }

        fn anyOfPredicate(ctx: *Context, expression: ast.Expression, negated: bool) Error!?Predicate {
            var subject: ?Operand = null;
            var literals: std.ArrayList(Operand) = .empty;
            if (!try collectDisjunction(ctx, expression, &subject, &literals)) return null;

            const args = try Adapter.allocator(ctx).alloc(Operand, literals.items.len + 1);
            args[0] = subject.?;
            for (literals.items, args[1..]) |literal, *slot| slot.* = literal;

            return Adapter.emit(if (negated) .not_any_of else .any_of, args);
        }

        fn collectDisjunction(
            ctx: *Context,
            expression: ast.Expression,
            subject: *?Operand,
            literals: *std.ArrayList(Operand),
        ) Error!bool {
            switch (expression) {
                .logical => |logical| {
                    if (logical.op != .@"or") return false;
                    if (!try collectDisjunction(ctx, logical.left.*, subject, literals)) return false;
                    return collectDisjunction(ctx, logical.right.*, subject, literals);
                },
                .compare => |compare| {
                    if (compare.op != .eq) return false;
                    const left = (try Adapter.textOperand(ctx, compare.left.*)) orelse return false;
                    const right = (try Adapter.textOperand(ctx, compare.right.*)) orelse return false;
                    const left_literal = Adapter.literalValue(left);
                    const right_literal = Adapter.literalValue(right);
                    if ((left_literal == null) == (right_literal == null)) return false;

                    const leaf_subject = if (left_literal != null) right else left;
                    const leaf_literal = if (left_literal != null) left else right;
                    if (!Adapter.isAnyOfSubject(leaf_subject)) return false;

                    if (subject.*) |seen| {
                        if (!Adapter.operandEql(seen, leaf_subject)) return false;
                    } else {
                        subject.* = leaf_subject;
                    }

                    try literals.append(Adapter.allocator(ctx), leaf_literal);
                    return true;
                },
                else => return false,
            }
        }
    };
}

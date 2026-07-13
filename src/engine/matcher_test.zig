const std = @import("std");
const mvzr = @import("mvzr");

const expr = @import("expr.zig");
const matcher = @import("matcher.zig");
const query = @import("query.zig");
const rule = @import("rule.zig");
const test_tree = @import("test_tree.zig");

const Node = @import("node.zig").Node;

fn firstOfKind(n: Node, kind_name: []const u8) ?Node {
    if (std.mem.eql(u8, n.kind(), kind_name)) return n;

    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const child = n.namedChild(i) orelse continue;
        if (firstOfKind(child, kind_name)) |found| return found;
    }

    return null;
}

fn evalOne(
    t: *const test_tree.Tree,
    source: []const u8,
    pred: rule.Predicate,
    match: query.Match,
) std.mem.Allocator.Error!bool {
    return matcher.evaluate(&.{pred}, match, .{
        .allocator = std.testing.allocator,
        .source = source,
        .root = t.root(),
    });
}

test "matcher: eq matches capture text against an equal string" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "foo" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .eq = &args }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_eq = &args }, match));
}

test "matcher: eq rejects differing capture and string texts" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "bar" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &args }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_eq = &args }, match));
}

test "matcher: eq compares two captures by text" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const frag = firstOfKind(t.root(), "string_fragment").?;
    const match: query.Match = .{ .nodes = &.{ ident, ident, frag } };

    var same = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .capture = 1 } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .eq = &same }, match));

    var different = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .capture = 2 } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &different }, match));
}

test "matcher: eq compares two string operands" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{} };

    var equal = [_]rule.PredicateOperand{ .{ .string = "a" }, .{ .string = "a" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .eq = &equal }, match));

    var different = [_]rule.PredicateOperand{ .{ .string = "a" }, .{ .string = "b" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &different }, match));
}

test "matcher: eq is false for an unbound capture regardless of negation" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ ident, null } };

    var args = [_]rule.PredicateOperand{ .{ .capture = 1 }, .{ .string = "foo" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &args }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_eq = &args }, match));
}

test "matcher: anyOf finds the capture text in the candidate list" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" }, .{ .string = "foo" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .any_of = &args }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_any_of = &args }, match));
}

test "matcher: anyOf misses when no candidate equals the capture text" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" }, .{ .string = "qux" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .any_of = &args }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_any_of = &args }, match));
}

test "matcher: anyOf skips unresolvable candidates" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ ident, null } };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .capture = 1 }, .{ .string = "foo" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .any_of = &args }, match));
}

test "matcher: startsWith checks the capture text prefix" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "fo" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .starts_with = &hit }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_starts_with = &hit }, match));

    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "oo" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .starts_with = &miss }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_starts_with = &miss }, match));
}

test "matcher: endsWith checks the capture text suffix" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "oo" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .ends_with = &hit }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_ends_with = &hit }, match));

    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "fo" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .ends_with = &miss }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_ends_with = &miss }, match));
}

test "matcher: contains checks for a substring of the capture text" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "o" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .contains = &hit }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_contains = &hit }, match));

    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "z" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .contains = &miss }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_contains = &miss }, match));
}

test "matcher: glob matches the capture text against a wildcard pattern" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "f*" } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .glob = &hit }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_glob = &hit }, match));

    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "b*" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .glob = &miss }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_glob = &miss }, match));
}

test "matcher: startsWith is false for an unbound capture" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{null} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "fo" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .starts_with = &args }, match));
}

test "matcher: regex match tests the capture text" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const hit: rule.RegexPredicate = .{ .args = &args, .regex = mvzr.compile("^fo").? };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .match = hit }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_match = hit }, match));

    const miss: rule.RegexPredicate = .{ .args = &args, .regex = mvzr.compile("^bar").? };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .match = miss }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_match = miss }, match));
}

test "matcher: captured reflects whether the capture slot is bound" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ ident, null } };

    var bound = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .captured = &bound }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_captured = &bound }, match));

    var unbound = [_]rule.PredicateOperand{.{ .capture = 1 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .captured = &unbound }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_captured = &unbound }, match));
}

test "matcher: captured treats a string operand as absent" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{} };

    var args = [_]rule.PredicateOperand{.{ .string = "foo" }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .captured = &args }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_captured = &args }, match));
}

test "matcher: eq is false when the operand count is not two" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var one = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &one }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_eq = &one }, match));

    var three = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "foo" }, .{ .string = "foo" } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .eq = &three }, match));
}

test "matcher: anyOf is false with fewer than two operands" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .any_of = &args }, match));
}

test "matcher: contains is false when the operand count is not two" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .contains = &args }, match));
}

test "matcher: captured is false when the operand count is not one" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .capture = 0 } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .captured = &args }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_captured = &args }, match));
}

test "matcher: anyGroup passes when one member passes" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" } };
    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "foo" } };
    var members = [_]rule.Predicate{ .{ .eq = &miss }, .{ .eq = &hit } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .any_group = &members }, match));
}

test "matcher: anyGroup fails when every member fails" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var first = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" } };
    var second = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "qux" } };
    var members = [_]rule.Predicate{ .{ .eq = &first }, .{ .eq = &second } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .any_group = &members }, match));
}

test "matcher: empty anyGroup fails and empty allGroup passes" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{} };

    var none = [_]rule.Predicate{};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .any_group = &none }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .all_group = &none }, match));
}

test "matcher: allGroup requires every member to pass" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "foo" } };
    var prefix = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "fo" } };
    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" } };

    var passing = [_]rule.Predicate{ .{ .eq = &hit }, .{ .starts_with = &prefix } };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .all_group = &passing }, match));

    var failing = [_]rule.Predicate{ .{ .eq = &hit }, .{ .eq = &miss } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .all_group = &failing }, match));
}

test "matcher: evaluate conjoins the top level predicate list" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };
    const ctx: matcher.EvalContext = .{
        .allocator = std.testing.allocator,
        .source = src,
        .root = t.root(),
    };

    try std.testing.expectEqual(true, try matcher.evaluate(&.{}, match, ctx));

    var hit = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "foo" } };
    var miss = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "baz" } };
    try std.testing.expectEqual(false, try matcher.evaluate(&.{ .{ .eq = &hit }, .{ .eq = &miss } }, match, ctx));
}

test "matcher: regex match is false when it has no operands" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };

    var args = [_]rule.PredicateOperand{};
    const pred: rule.RegexPredicate = .{ .args = &args, .regex = mvzr.compile("^fo").? };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .match = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_match = pred }, match));
}

test "matcher: regex match is false for an unbound capture" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{null} };

    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.RegexPredicate = .{ .args = &args, .regex = mvzr.compile("^fo").? };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .match = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_match = pred }, match));
}

test "matcher: has finds a matching descendant of the subject" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const with_calls = t.root().namedChild(0).?;
    const without_calls = t.root().namedChild(1).?;

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    const hit: query.Match = .{ .nodes = &.{with_calls} };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .has = pred }, hit));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_has = pred }, hit));

    const miss: query.Match = .{ .nodes = &.{without_calls} };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = pred }, miss));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_has = pred }, miss));
}

test "matcher: has applies nested predicates to each candidate" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const with_calls = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{with_calls} };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    var accept_args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "h()" } };
    var accept = [_]rule.Predicate{.{ .eq = &accept_args }};
    const accepting: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &accept,
    };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .has = .{ .args = &args, .matcher = &accepting } }, match));

    var reject_args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "z()" } };
    var reject = [_]rule.Predicate{.{ .eq = &reject_args }};
    const rejecting: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &reject,
    };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = .{ .args = &args, .matcher = &rejecting } }, match));
}

test "matcher: has rejects the subject matching itself" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const subject = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{subject} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("function_declaration") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: has is false without a usable subject" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const subject = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{ subject, null } };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };

    var two = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .capture = 0 } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = .{ .args = &two, .matcher = &nested } }, match));

    var string_subject = [_]rule.PredicateOperand{.{ .string = "f" }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = .{ .args = &string_subject, .matcher = &nested } }, match));

    var unbound = [_]rule.PredicateOperand{.{ .capture = 1 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .has = .{ .args = &unbound, .matcher = &nested } }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_has = .{ .args = &unbound, .matcher = &nested } }, match));
}

test "matcher: count compares the nested match total with every operator" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const subject = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{subject} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    const cases = [_]struct { op: expr.Compare, value: u32, expected: bool }{
        .{ .op = .eq, .value = 2, .expected = true },
        .{ .op = .ne, .value = 2, .expected = false },
        .{ .op = .gt, .value = 1, .expected = true },
        .{ .op = .ge, .value = 3, .expected = false },
        .{ .op = .lt, .value = 3, .expected = true },
        .{ .op = .le, .value = 1, .expected = false },
    };
    for (cases) |case| {
        const pred: rule.CountPredicate = .{
            .args = &args,
            .matcher = &nested,
            .compare = .{ .op = case.op, .value = case.value },
        };
        try std.testing.expectEqual(case.expected, try evalOne(&t, src, .{ .count = pred }, match));
    }
}

test "matcher: count is false without a usable subject" {
    const src = "function f() { g(); h(); } function empty() {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{null} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("call_expression") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var unbound = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.CountPredicate = .{
        .args = &unbound,
        .matcher = &nested,
        .compare = .{ .op = .eq, .value = 0 },
    };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .count = pred }, match));
}

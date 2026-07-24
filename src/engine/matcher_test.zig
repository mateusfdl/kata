const std = @import("std");
const mvzr = @import("mvzr");

const expr = @import("expr.zig");
const matcher = @import("matcher.zig");
const metric = @import("metric.zig");
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

fn evalOneMetric(
    t: *const test_tree.Tree,
    source: []const u8,
    compiled: *const metric.Compiled,
    pred: rule.Predicate,
    match: query.Match,
) std.mem.Allocator.Error!bool {
    return matcher.evaluate(&.{pred}, match, .{
        .allocator = std.testing.allocator,
        .source = source,
        .root = t.root(),
        .metric = .{
            .allocator = std.testing.allocator,
            .compiled = compiled,
            .fam = t.lang.family(),
        },
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

test "matcher: inside finds a matching ancestor of the subject" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const statement = firstOfKind(t.root(), "expression_statement").?;
    const outer_fn = t.root().namedChild(0).?;

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("if_statement") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    const enclosed: query.Match = .{ .nodes = &.{statement} };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .inside = pred }, enclosed));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_inside = pred }, enclosed));

    const outside: query.Match = .{ .nodes = &.{outer_fn} };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .inside = pred }, outside));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_inside = pred }, outside));
}

test "matcher: inside excludes the subject matching itself" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const outer_fn = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{outer_fn} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("function_declaration") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .inside = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: inside stops at an until boundary" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const statement = firstOfKind(t.root(), "expression_statement").?;
    const match: query.Match = .{ .nodes = &.{statement} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("if_statement") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const until = [_]u16{t.sym("function_declaration")};

    const blocked: rule.NestedPredicate = .{ .args = &args, .matcher = &nested, .until_kinds = &until };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .inside = blocked }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_inside = blocked }, match));
}

test "matcher: inside accepts an ancestor reached before the until boundary" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const statement = firstOfKind(t.root(), "expression_statement").?;
    const match: query.Match = .{ .nodes = &.{statement} };

    var none = [_]rule.Predicate{};
    const nested: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("statement_block") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const until = [_]u16{t.sym("if_statement")};

    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested, .until_kinds = &until };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .inside = pred }, match));
}

test "matcher: inside applies nested predicates to candidate ancestors" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const statement = firstOfKind(t.root(), "expression_statement").?;
    const match: query.Match = .{ .nodes = &.{statement} };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    var outer_args = [_]rule.PredicateOperand{ .{ .capture = 1 }, .{ .string = "outer" } };
    var wants_outer = [_]rule.Predicate{.{ .eq = &outer_args }};
    const named_outer: rule.NestedMatcher = .{
        .pattern = .{
            .kind = .{ .symbol = t.sym("function_declaration") },
            .capture = 0,
            .fields = &.{.{
                .relation = .{ .field = t.field("name") },
                .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 1 },
            }},
        },
        .capture_count = 2,
        .root_capture_id = 0,
        .predicates = &wants_outer,
    };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .inside = .{ .args = &args, .matcher = &named_outer } }, match));

    var missing_args = [_]rule.PredicateOperand{ .{ .capture = 1 }, .{ .string = "missing" } };
    var wants_missing = [_]rule.Predicate{.{ .eq = &missing_args }};
    const named_missing: rule.NestedMatcher = .{
        .pattern = .{
            .kind = .{ .symbol = t.sym("function_declaration") },
            .capture = 0,
            .fields = &.{.{
                .relation = .{ .field = t.field("name") },
                .pattern = .{ .kind = .{ .symbol = t.sym("identifier") }, .capture = 1 },
            }},
        },
        .capture_count = 2,
        .root_capture_id = 0,
        .predicates = &wants_missing,
    };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .inside = .{ .args = &args, .matcher = &named_missing } }, match));
}

test "matcher: parent only accepts the direct parent" {
    const src = "function outer() { if (x) { function inner() { y; } } }";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const if_stmt = firstOfKind(t.root(), "if_statement").?;
    const match: query.Match = .{ .nodes = &.{if_stmt} };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    var none = [_]rule.Predicate{};
    const block: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("statement_block") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &none,
    };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .parent = .{ .args = &args, .matcher = &block } }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_parent = .{ .args = &args, .matcher = &block } }, match));

    var grand_none = [_]rule.Predicate{};
    const grandparent: rule.NestedMatcher = .{
        .pattern = .{ .kind = .{ .symbol = t.sym("function_declaration") }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = &grand_none,
    };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .parent = .{ .args = &args, .matcher = &grandparent } }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_parent = .{ .args = &args, .matcher = &grandparent } }, match));
}

test "matcher: where is false without a metric context" {
    const src = "function f(a, b) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const fn_node = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{fn_node} };

    const e: expr.Expr = .{ .compare = .{
        .op = .gt,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 1 },
    } };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .where = &e }, match));
}

test "matcher: where compares the params measure of the capture" {
    const src = "function f(a, b) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const fn_node = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{fn_node} };

    const above: expr.Expr = .{ .compare = .{
        .op = .gt,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 1 },
    } };
    try std.testing.expectEqual(true, try evalOneMetric(&t, src, &compiled, .{ .where = &above }, match));

    const beyond: expr.Expr = .{ .compare = .{
        .op = .ge,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 3 },
    } };
    try std.testing.expectEqual(false, try evalOneMetric(&t, src, &compiled, .{ .where = &beyond }, match));
}

test "matcher: where counts go parameters through the family adapter" {
    const src = "package main\nfunc f(a int) {}";
    var t = test_tree.build(std.testing.allocator, .go, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const fn_node = firstOfKind(t.root(), "function_declaration").?;
    const match: query.Match = .{ .nodes = &.{fn_node} };

    const exactly_one: expr.Expr = .{ .compare = .{
        .op = .eq,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 1 },
    } };
    try std.testing.expectEqual(true, try evalOneMetric(&t, src, &compiled, .{ .where = &exactly_one }, match));

    const more: expr.Expr = .{ .compare = .{
        .op = .gt,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 1 },
    } };
    try std.testing.expectEqual(false, try evalOneMetric(&t, src, &compiled, .{ .where = &more }, match));
}

test "matcher: where text measure parses numeric capture text" {
    const src = "const n = 42;";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const number = firstOfKind(t.root(), "number").?;
    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ number, ident } };

    const numeric: expr.Expr = .{ .compare = .{
        .op = .eq,
        .left = .{ .measure = .{ .measure = .text, .capture_id = 0 } },
        .right = .{ .number = 42 },
    } };
    try std.testing.expectEqual(true, try evalOneMetric(&t, src, &compiled, .{ .where = &numeric }, match));

    const non_numeric: expr.Expr = .{ .compare = .{
        .op = .eq,
        .left = .{ .measure = .{ .measure = .text, .capture_id = 1 } },
        .right = .{ .number = 42 },
    } };
    try std.testing.expectEqual(false, try evalOneMetric(&t, src, &compiled, .{ .where = &non_numeric }, match));
}

test "matcher: where is false for an unbound capture measure" {
    const src = "function f(a, b) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{null} };

    const e: expr.Expr = .{ .compare = .{
        .op = .ge,
        .left = .{ .measure = .{ .measure = .params, .capture_id = 0 } },
        .right = .{ .number = 0 },
    } };
    try std.testing.expectEqual(false, try evalOneMetric(&t, src, &compiled, .{ .where = &e }, match));
}

test "matcher: renderMessage concatenates literals and capture text" {
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

    const segments = [_]rule.MessageSegment{
        .{ .literal = "name: " },
        .{ .placeholder = .{ .measure = .text, .capture_id = 0 } },
    };
    const msg = try matcher.renderMessage(std.testing.allocator, &segments, match, ctx);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("name: foo", msg);
}

test "matcher: renderMessage falls back for an unbound text placeholder" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{null} };
    const ctx: matcher.EvalContext = .{
        .allocator = std.testing.allocator,
        .source = src,
        .root = t.root(),
    };

    const segments = [_]rule.MessageSegment{
        .{ .placeholder = .{ .measure = .text, .capture_id = 0 } },
    };
    const msg = try matcher.renderMessage(std.testing.allocator, &segments, match, ctx);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("?", msg);
}

test "matcher: renderMessage renders numeric measures with a metric context" {
    const src = "function f(a, b) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const fn_node = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{fn_node} };
    const ctx: matcher.EvalContext = .{
        .allocator = std.testing.allocator,
        .source = src,
        .root = t.root(),
        .metric = .{
            .allocator = std.testing.allocator,
            .compiled = &compiled,
            .fam = t.lang.family(),
        },
    };

    const segments = [_]rule.MessageSegment{
        .{ .literal = "params: " },
        .{ .placeholder = .{ .measure = .params, .capture_id = 0 } },
    };
    const msg = try matcher.renderMessage(std.testing.allocator, &segments, match, ctx);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("params: 2", msg);
}

test "matcher: renderMessage falls back for measures without a metric context" {
    const src = "function f(a, b) {}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const fn_node = t.root().namedChild(0).?;
    const match: query.Match = .{ .nodes = &.{fn_node} };
    const ctx: matcher.EvalContext = .{
        .allocator = std.testing.allocator,
        .source = src,
        .root = t.root(),
    };

    const segments = [_]rule.MessageSegment{
        .{ .placeholder = .{ .measure = .params, .capture_id = 0 } },
    };
    const msg = try matcher.renderMessage(std.testing.allocator, &segments, match, ctx);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("?", msg);
}

test "matcher: renderMessage falls back when the measure resolves to nothing" {
    const src = "const foo = \"bar\";";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    var compiled = try metric.compile(std.testing.allocator, t.lang.family());
    defer compiled.deinit(std.testing.allocator);

    const ident = firstOfKind(t.root(), "identifier").?;
    const match: query.Match = .{ .nodes = &.{ident} };
    const ctx: matcher.EvalContext = .{
        .allocator = std.testing.allocator,
        .source = src,
        .root = t.root(),
        .metric = .{
            .allocator = std.testing.allocator,
            .compiled = &compiled,
            .fam = t.lang.family(),
        },
    };

    const segments = [_]rule.MessageSegment{
        .{ .placeholder = .{ .measure = .args, .capture_id = 0 } },
    };
    const msg = try matcher.renderMessage(std.testing.allocator, &segments, match, ctx);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("?", msg);
}

fn statementBlock(t: *const test_tree.Tree) Node {
    return firstOfKind(t.root(), "statement_block").?;
}

fn simpleNested(t: *const test_tree.Tree, kind_name: []const u8, predicates: []rule.Predicate) rule.NestedMatcher {
    return .{
        .pattern = .{ .kind = .{ .symbol = t.sym(kind_name) }, .capture = 0 },
        .capture_count = 1,
        .root_capture_id = 0,
        .predicates = predicates,
    };
}

test "matcher: follows finds a later sibling" {
    const src = "function f(){a();b();c();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const block = statementBlock(&t);
    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    const first: query.Match = .{ .nodes = &.{block.namedChild(0).?} };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .follows = pred }, first));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_follows = pred }, first));

    const last: query.Match = .{ .nodes = &.{block.namedChild(2).?} };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = pred }, last));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_follows = pred }, last));
}

test "matcher: follows accepts a sibling starting at the subject's end byte" {
    const src = "function f(){a();b();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const block = statementBlock(&t);
    const subject = block.namedChild(0).?;
    const next = block.namedChild(1).?;
    try std.testing.expectEqual(subject.endByte(), next.startByte());

    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const match: query.Match = .{ .nodes = &.{subject} };

    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .follows = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: follows ignores earlier siblings" {
    const src = "function f(){a();b();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const block = statementBlock(&t);
    const match: query.Match = .{ .nodes = &.{block.namedChild(1).?} };

    var only_first = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "a();" } };
    var predicates = [_]rule.Predicate{.{ .eq = &only_first }};
    const nested = simpleNested(&t, "expression_statement", &predicates);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = .{ .args = &args, .matcher = &nested } }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .precedes = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: follows and precedes are false for an only child" {
    const src = "function f(){a();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{statementBlock(&t).namedChild(0).?} };

    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = pred }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_follows = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .precedes = pred }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_precedes = pred }, match));
}

test "matcher: follows is false for a subject without a parent" {
    const src = "function f(){a();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{t.root()} };

    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "function_declaration", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = pred }, match));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_follows = pred }, match));
}

test "matcher: follows applies nested predicates to each candidate" {
    const src = "function f(){a();b();c();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{statementBlock(&t).namedChild(0).?} };
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    var accept_args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "c();" } };
    var accept = [_]rule.Predicate{.{ .eq = &accept_args }};
    const accepting = simpleNested(&t, "expression_statement", &accept);
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .follows = .{ .args = &args, .matcher = &accepting } }, match));

    var reject_args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "z();" } };
    var reject = [_]rule.Predicate{.{ .eq = &reject_args }};
    const rejecting = simpleNested(&t, "expression_statement", &reject);
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = .{ .args = &args, .matcher = &rejecting } }, match));
}

test "matcher: follows does not descend into a sibling" {
    const src = "function f(){a();(function(){b();});}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{statementBlock(&t).namedChild(0).?} };

    var inner_args = [_]rule.PredicateOperand{ .{ .capture = 0 }, .{ .string = "b();" } };
    var predicates = [_]rule.Predicate{.{ .eq = &inner_args }};
    const nested = simpleNested(&t, "expression_statement", &predicates);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};

    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: precedes finds an earlier sibling" {
    const src = "function f(){a();b();c();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const block = statementBlock(&t);
    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const pred: rule.NestedPredicate = .{ .args = &args, .matcher = &nested };

    const last: query.Match = .{ .nodes = &.{block.namedChild(2).?} };
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .precedes = pred }, last));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_precedes = pred }, last));

    const first: query.Match = .{ .nodes = &.{block.namedChild(0).?} };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .precedes = pred }, first));
    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .not_precedes = pred }, first));
}

test "matcher: precedes accepts a sibling ending at the subject's start byte" {
    const src = "function f(){a();b();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const block = statementBlock(&t);
    const subject = block.namedChild(1).?;
    try std.testing.expectEqual(subject.startByte(), block.namedChild(0).?.endByte());

    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);
    var args = [_]rule.PredicateOperand{.{ .capture = 0 }};
    const match: query.Match = .{ .nodes = &.{subject} };

    try std.testing.expectEqual(true, try evalOne(&t, src, .{ .precedes = .{ .args = &args, .matcher = &nested } }, match));
}

test "matcher: follows and precedes are false without a usable subject" {
    const src = "function f(){a();b();}";
    var t = test_tree.build(std.testing.allocator, .ts, src);
    defer t.deinit(std.testing.allocator);

    const match: query.Match = .{ .nodes = &.{ statementBlock(&t).namedChild(0).?, null } };

    var none = [_]rule.Predicate{};
    const nested = simpleNested(&t, "expression_statement", &none);

    var unbound = [_]rule.PredicateOperand{.{ .capture = 1 }};
    const pred: rule.NestedPredicate = .{ .args = &unbound, .matcher = &nested };
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_follows = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .precedes = pred }, match));
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .not_precedes = pred }, match));

    var string_subject = [_]rule.PredicateOperand{.{ .string = "a();" }};
    try std.testing.expectEqual(false, try evalOne(&t, src, .{ .follows = .{ .args = &string_subject, .matcher = &nested } }, match));
}

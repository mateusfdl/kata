const std = @import("std");
const mvzr = @import("mvzr");

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

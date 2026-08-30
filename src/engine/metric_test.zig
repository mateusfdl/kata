const std = @import("std");
const nk = @import("node_kinds");

const family = @import("family/family.zig");
const metric = @import("metric.zig");
const node = @import("node.zig");
const test_tree = @import("test_tree.zig");
const Node = node.Node;

const MetricKind = metric.MetricKind;

fn tsId(comptime name: []const u8) u16 {
    return @intFromEnum(@field(nk.ts_family.Kind, name));
}

fn goId(comptime name: []const u8) u16 {
    return @intFromEnum(@field(nk.go.Kind, name));
}

fn collectBinary(n: Node, out: *std.ArrayList(Node), gpa: std.mem.Allocator) !void {
    if (std.mem.eql(u8, n.kind(), "binary_expression")) try out.append(gpa, n);
    var children = n.children();
    while (children.next()) |c| try collectBinary(c, out, gpa);
}

fn firstOfKind(n: Node, kind: []const u8) ?Node {
    if (std.mem.eql(u8, n.kind(), kind)) return n;
    var children = n.children();
    while (children.next()) |child| {
        if (firstOfKind(child, kind)) |found| return found;
    }
    return null;
}

fn walkClassifyAll(n: Node, compiled: *const metric.Compiled) void {
    _ = metric.classify(compiled, n);
    var children = n.children();
    while (children.next()) |c| walkClassifyAll(c, compiled);
}

test "metric: ts table classifies decision points by kind" {
    const gpa = std.testing.allocator;
    const table = try family.of(.ts_family).buildMetricTable(gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.branch, table[tsId("if_statement")].?);
    try std.testing.expectEqual(MetricKind.function, table[tsId("arrow_function")].?);
    try std.testing.expectEqual(MetricKind.function, table[tsId("method_definition")].?);
    try std.testing.expectEqual(MetricKind.ternary, table[tsId("ternary_expression")].?);
    try std.testing.expectEqual(MetricKind.loop, table[tsId("while_statement")].?);
    try std.testing.expectEqual(MetricKind.loop, table[tsId("for_in_statement")].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[tsId("switch_statement")].?);
    try std.testing.expectEqual(MetricKind.case, table[tsId("switch_case")].?);
    try std.testing.expectEqual(MetricKind.catch_clause, table[tsId("catch_clause")].?);
    try std.testing.expectEqual(MetricKind.bool_op, table[tsId("binary_expression")].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[tsId("identifier")]);
}

test "metric: tsx-only kinds share the ts_family table" {
    const gpa = std.testing.allocator;
    const table = try family.of(.ts_family).buildMetricTable(gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.branch, table[tsId("if_statement")].?);
    try std.testing.expectEqual(MetricKind.function, table[tsId("arrow_function")].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[tsId("jsx_element")]);
}

test "metric: go table classifies decision points by kind" {
    const gpa = std.testing.allocator;
    const table = try family.of(.go).buildMetricTable(gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.function, table[goId("method_declaration")].?);
    try std.testing.expectEqual(MetricKind.function, table[goId("func_literal")].?);
    try std.testing.expectEqual(MetricKind.branch, table[goId("if_statement")].?);
    try std.testing.expectEqual(MetricKind.loop, table[goId("for_statement")].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[goId("expression_switch_statement")].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[goId("select_statement")].?);
    try std.testing.expectEqual(MetricKind.case, table[goId("communication_case")].?);
    try std.testing.expectEqual(MetricKind.bool_op, table[goId("binary_expression")].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[goId("identifier")]);
}

test "metric: bool-op refinement counts only logical binary operators in ts" {
    const gpa = std.testing.allocator;
    var compiled = try metric.compile(gpa, .ts_family);
    defer compiled.deinit(gpa);

    var t = test_tree.build(gpa, .ts, "const x = a && b || (c ?? d); const y = a + b;");
    defer t.deinit(gpa);

    var binaries: std.ArrayList(Node) = .empty;
    defer binaries.deinit(gpa);
    try collectBinary(t.root(), &binaries, gpa);

    var logical: usize = 0;
    var arithmetic: usize = 0;
    for (binaries.items) |bin| {
        const op = bin.childByFieldName("operator").?.kind();
        const result = metric.classify(&compiled, bin);
        if (std.mem.eql(u8, op, "+")) {
            arithmetic += 1;
            try std.testing.expectEqual(@as(?MetricKind, null), result);
        } else {
            logical += 1;
            try std.testing.expectEqual(MetricKind.bool_op, result.?);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), logical);
    try std.testing.expectEqual(@as(usize, 1), arithmetic);
}

test "metric: bool-op refinement counts only logical binary operators in go" {
    const gpa = std.testing.allocator;
    var compiled = try metric.compile(gpa, .go);
    defer compiled.deinit(gpa);

    var t = test_tree.build(gpa, .go, "package main\nfunc f(a bool, b int) {\n\t_ = a && a\n\t_ = b + b\n}\n");
    defer t.deinit(gpa);

    var binaries: std.ArrayList(Node) = .empty;
    defer binaries.deinit(gpa);
    try collectBinary(t.root(), &binaries, gpa);

    try std.testing.expectEqual(@as(usize, 2), binaries.items.len);
    for (binaries.items) |bin| {
        const op = bin.childByFieldName("operator").?.kind();
        const result = metric.classify(&compiled, bin);
        if (std.mem.eql(u8, op, "&&")) {
            try std.testing.expectEqual(MetricKind.bool_op, result.?);
        } else {
            try std.testing.expectEqual(@as(?MetricKind, null), result);
        }
    }
}

test "metric: params preserves ts single-parameter fields" {
    const gpa = std.testing.allocator;
    var t = test_tree.build(gpa, .ts, "const f = value => value;");
    defer t.deinit(gpa);

    const arrow = firstOfKind(t.root(), "arrow_function").?;
    try std.testing.expectEqual(@as(?u32, 1), metric.paramsOf(arrow, .ts_family));
}

test "metric: ts nullish coalescing increases complexity" {
    const gpa = std.testing.allocator;
    var t = test_tree.build(gpa, .ts, "function f(a, b) { return a ?? b; }");
    defer t.deinit(gpa);

    var compiled = try metric.compile(gpa, .ts_family);
    defer compiled.deinit(gpa);
    var analysis = try metric.analyze(gpa, &compiled, t.root().namedChild(0).?);
    defer analysis.deinit();

    try std.testing.expectEqual(metric.Measures{ .complexity = 2, .nesting = 0 }, try analysis.measures());
}

test "metric: classify tolerates error nodes without indexing out of range" {
    const gpa = std.testing.allocator;
    var compiled = try metric.compile(gpa, .ts_family);
    defer compiled.deinit(gpa);

    var t = test_tree.build(gpa, .ts, "function (");
    defer t.deinit(gpa);

    walkClassifyAll(t.root(), &compiled);
}

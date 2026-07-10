const std = @import("std");
const ts = @import("tree_sitter");

const kinds = @import("kinds.zig");
const language = @import("language.zig");
const Node = @import("node.zig").Node;

const MetricKind = kinds.MetricKind;

fn parse(lang: language.Name, source: []const u8) *ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language.grammar(lang)) catch unreachable;
    return parser.parseString(source, null).?;
}

fn collectBinary(node: Node, out: *std.ArrayList(Node), gpa: std.mem.Allocator) !void {
    if (std.mem.eql(u8, node.kind(), "binary_expression")) try out.append(gpa, node);
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (node.child(i)) |c| try collectBinary(c, out, gpa);
    }
}

fn walkClassifyAll(node: Node, table: []const ?MetricKind) void {
    _ = kinds.classify(table, node);
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (node.child(i)) |c| walkClassifyAll(c, table);
    }
}

test "kinds: ts table classifies decision points by kind" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.ts);
    const table = try kinds.buildTsTable(grammar, gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.branch, table[grammar.idForNodeKind("if_statement", true)].?);
    try std.testing.expectEqual(MetricKind.function, table[grammar.idForNodeKind("arrow_function", true)].?);
    try std.testing.expectEqual(MetricKind.function, table[grammar.idForNodeKind("method_definition", true)].?);
    try std.testing.expectEqual(MetricKind.ternary, table[grammar.idForNodeKind("ternary_expression", true)].?);
    try std.testing.expectEqual(MetricKind.loop, table[grammar.idForNodeKind("while_statement", true)].?);
    try std.testing.expectEqual(MetricKind.loop, table[grammar.idForNodeKind("for_in_statement", true)].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[grammar.idForNodeKind("switch_statement", true)].?);
    try std.testing.expectEqual(MetricKind.case, table[grammar.idForNodeKind("switch_case", true)].?);
    try std.testing.expectEqual(MetricKind.catch_clause, table[grammar.idForNodeKind("catch_clause", true)].?);
    try std.testing.expectEqual(MetricKind.bool_op, table[grammar.idForNodeKind("binary_expression", true)].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[grammar.idForNodeKind("identifier", true)]);
}

test "kinds: tsx table shares the ts_family classification" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.tsx);
    const table = try kinds.buildTsTable(grammar, gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.branch, table[grammar.idForNodeKind("if_statement", true)].?);
    try std.testing.expectEqual(MetricKind.function, table[grammar.idForNodeKind("arrow_function", true)].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[grammar.idForNodeKind("jsx_element", true)]);
}

test "kinds: go table classifies decision points by kind" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.go);
    const table = try kinds.buildGoTable(grammar, gpa);
    defer gpa.free(table);

    try std.testing.expectEqual(MetricKind.function, table[grammar.idForNodeKind("method_declaration", true)].?);
    try std.testing.expectEqual(MetricKind.function, table[grammar.idForNodeKind("func_literal", true)].?);
    try std.testing.expectEqual(MetricKind.branch, table[grammar.idForNodeKind("if_statement", true)].?);
    try std.testing.expectEqual(MetricKind.loop, table[grammar.idForNodeKind("for_statement", true)].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[grammar.idForNodeKind("expression_switch_statement", true)].?);
    try std.testing.expectEqual(MetricKind.switch_stmt, table[grammar.idForNodeKind("select_statement", true)].?);
    try std.testing.expectEqual(MetricKind.case, table[grammar.idForNodeKind("communication_case", true)].?);
    try std.testing.expectEqual(MetricKind.bool_op, table[grammar.idForNodeKind("binary_expression", true)].?);
    try std.testing.expectEqual(@as(?MetricKind, null), table[grammar.idForNodeKind("identifier", true)]);
}

test "kinds: bool-op refinement counts only logical binary operators in ts" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.ts);
    const table = try kinds.buildTsTable(grammar, gpa);
    defer gpa.free(table);

    const tree = parse(.ts, "const x = a && b || (c ?? d); const y = a + b;");
    defer tree.destroy();

    var binaries: std.ArrayList(Node) = .empty;
    defer binaries.deinit(gpa);
    try collectBinary(Node.from(tree.rootNode()), &binaries, gpa);

    var logical: usize = 0;
    var arithmetic: usize = 0;
    for (binaries.items) |bin| {
        const op = bin.childByFieldName("operator").?.kind();
        const result = kinds.classify(table, bin);
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

test "kinds: bool-op refinement counts only logical binary operators in go" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.go);
    const table = try kinds.buildGoTable(grammar, gpa);
    defer gpa.free(table);

    const tree = parse(.go, "package main\nfunc f(a bool, b int) {\n\t_ = a && a\n\t_ = b + b\n}\n");
    defer tree.destroy();

    var binaries: std.ArrayList(Node) = .empty;
    defer binaries.deinit(gpa);
    try collectBinary(Node.from(tree.rootNode()), &binaries, gpa);

    try std.testing.expectEqual(@as(usize, 2), binaries.items.len);
    for (binaries.items) |bin| {
        const op = bin.childByFieldName("operator").?.kind();
        const result = kinds.classify(table, bin);
        if (std.mem.eql(u8, op, "&&")) {
            try std.testing.expectEqual(MetricKind.bool_op, result.?);
        } else {
            try std.testing.expectEqual(@as(?MetricKind, null), result);
        }
    }
}

test "kinds: classify tolerates error nodes without indexing out of range" {
    const gpa = std.testing.allocator;
    const grammar = language.grammar(.ts);
    const table = try kinds.buildTsTable(grammar, gpa);
    defer gpa.free(table);

    const tree = parse(.ts, "function (");
    defer tree.destroy();

    walkClassifyAll(Node.from(tree.rootNode()), table);
}

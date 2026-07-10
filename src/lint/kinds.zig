const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");
const Node = @import("node.zig").Node;

pub const MetricKind = enum {
    function,
    branch,
    ternary,
    loop,
    case,
    switch_stmt,
    catch_clause,
    bool_op,
};

fn tsClassify(k: node_kinds.ts_family.Kind) ?MetricKind {
    return switch (k) {
        .function_declaration,
        .function_expression,
        .generator_function_declaration,
        .generator_function,
        .arrow_function,
        .method_definition,
        => .function,
        .if_statement => .branch,
        .ternary_expression => .ternary,
        .for_statement,
        .for_in_statement,
        .while_statement,
        .do_statement,
        => .loop,
        .switch_statement => .switch_stmt,
        .switch_case => .case,
        .catch_clause => .catch_clause,
        .binary_expression => .bool_op,
        else => null,
    };
}

fn goClassify(k: node_kinds.go.Kind) ?MetricKind {
    return switch (k) {
        .function_declaration,
        .method_declaration,
        .func_literal,
        => .function,
        .if_statement => .branch,
        .for_statement => .loop,
        .expression_switch_statement,
        .type_switch_statement,
        .select_statement,
        => .switch_stmt,
        .expression_case,
        .type_case,
        .communication_case,
        => .case,
        .binary_expression => .bool_op,
        else => null,
    };
}

pub fn buildTsTable(grammar: *const ts.Language, gpa: std.mem.Allocator) ![]?MetricKind {
    return buildTable(node_kinds.ts_family.Kind, tsClassify, grammar, gpa);
}

pub fn buildGoTable(grammar: *const ts.Language, gpa: std.mem.Allocator) ![]?MetricKind {
    return buildTable(node_kinds.go.Kind, goClassify, grammar, gpa);
}

fn buildTable(
    comptime Kind: type,
    comptime classifyKind: fn (Kind) ?MetricKind,
    grammar: *const ts.Language,
    gpa: std.mem.Allocator,
) ![]?MetricKind {
    const table = try gpa.alloc(?MetricKind, grammar.nodeKindCount());
    @memset(table, null);
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        if (classifyKind(@enumFromInt(f.value))) |mk| {
            const sym = grammar.idForNodeKind(f.name, true);
            if (sym != 0) table[sym] = mk;
        }
    }
    return table;
}

pub fn classify(table: []const ?MetricKind, node: Node) ?MetricKind {
    const sym = node.symbol();
    if (sym >= table.len) return null;
    const mk = table[sym] orelse return null;
    if (mk == .bool_op) {
        const op = node.childByFieldName("operator") orelse return null;
        if (!isLogicalOperator(op.kind())) return null;
    }
    return mk;
}

fn isLogicalOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "&&") or
        std.mem.eql(u8, op, "||") or
        std.mem.eql(u8, op, "??");
}

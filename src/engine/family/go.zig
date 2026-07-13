const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const family = @import("family.zig");
const metric = @import("../metric.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.go;
const fields = family.FieldFns(kinds.Field);
const metric_table = family.MetricTable(kinds.Kind, kinds.kind_count, classifyMetric);

pub const adapter: family.Adapter = .{
    .supertypes = &kinds.supertypes,
    .kindName = kinds.name,
    .fieldId = fields.id,
    .fieldName = fields.name,
    .buildKindRemap = buildKindRemap,
    .buildFieldRemap = buildFieldRemap,
    .buildMetricTable = metric_table.build,
    .paramCount = paramCount,
};

fn classifyMetric(k: kinds.Kind) ?metric.MetricKind {
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

fn paramCount(params: Node) u32 {
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < params.namedChildCount()) : (i += 1) {
        const decl = params.namedChild(i) orelse continue;
        if (!isParameterDeclaration(decl)) continue;
        const names = countFieldChildren(decl, "name");
        total += if (names == 0) 1 else names;
    }
    return total;
}

fn isParameterDeclaration(node: Node) bool {
    const kind = node.kind();
    return std.mem.eql(u8, kind, "parameter_declaration") or
        std.mem.eql(u8, kind, "variadic_parameter_declaration");
}

fn countFieldChildren(node: Node, field: []const u8) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const name = node.fieldNameForChild(i) orelse continue;
        if (std.mem.eql(u8, name, field)) count += 1;
    }
    return count;
}

fn buildKindRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildKindRemap(grammar, gpa);
}

fn buildFieldRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildFieldRemap(grammar, gpa);
}

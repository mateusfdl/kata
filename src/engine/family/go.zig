const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const facts = @import("../facts.zig");
const family = @import("family.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
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
    .fact_patterns = fact_patterns,
    .resolveContainers = resolveContainers,
    .relative_import_specifiers = false,
};

fn sym(comptime name: []const u8) u16 {
    return @intFromEnum(@field(kinds.Kind, name));
}

fn fld(comptime field: kinds.Field) u16 {
    return @intFromEnum(field);
}

const cap = facts.cap;

const fact_patterns: []const query.Pattern = &.{
    .{ .kind = .{ .symbol = sym("type_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_spec") }, .fields = &.{
            .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.class_name) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("method_declaration") }, .capture = cap(.method_node), .fields = &.{
        .{ .relation = .{ .field = fld(.receiver) }, .pattern = .{ .kind = .{ .symbol = sym("parameter_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("parameter_declaration") }, .fields = &.{
                .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .alternation = &.{
                    .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.method_recv) },
                    .{ .kind = .{ .symbol = sym("pointer_type") }, .fields = &.{
                        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.method_recv) } },
                    } },
                } } } },
            } } },
        } } },
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("field_identifier") }, .capture = cap(.method_name) } },
    } },
    .{ .kind = .{ .symbol = sym("parameter_declaration") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = sym("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = sym("field_declaration") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("field_identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = sym("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = sym("var_spec") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) },
            .{ .kind = .{ .symbol = sym("pointer_type") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
            } },
        } } } },
    } },
    .{ .kind = .{ .symbol = sym("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = fld(.left) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = fld(.right) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("call_expression") }, .fields = &.{
                .{ .relation = .{ .field = fld(.function) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_ctor) } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = fld(.left) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = fld(.right) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("composite_literal") }, .fields = &.{
                .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("short_var_declaration") }, .fields = &.{
        .{ .relation = .{ .field = fld(.left) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = fld(.right) }, .pattern = .{ .kind = .{ .symbol = sym("expression_list") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("unary_expression") }, .fields = &.{
                .{ .relation = .{ .field = fld(.operand) }, .pattern = .{ .kind = .{ .symbol = sym("composite_literal") }, .fields = &.{
                    .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
                } } },
            } } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = fld(.function) }, .pattern = .{ .kind = .{ .symbol = sym("selector_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.operand) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.call_receiver) } },
            .{ .relation = .{ .field = fld(.field) }, .pattern = .{ .kind = .{ .symbol = sym("field_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = fld(.function) }, .pattern = .{ .kind = .{ .symbol = sym("selector_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.operand) }, .pattern = .{ .kind = .{ .symbol = sym("selector_expression") }, .fields = &.{
                .{ .relation = .{ .field = fld(.field) }, .pattern = .{ .kind = .{ .symbol = sym("field_identifier") }, .capture = cap(.call_receiver) } },
            } } },
            .{ .relation = .{ .field = fld(.field) }, .pattern = .{ .kind = .{ .symbol = sym("field_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("import_spec") }, .fields = &.{
        .{ .relation = .{ .field = fld(.path) }, .pattern = .{ .kind = .{ .symbol = sym("interpreted_string_literal") }, .capture = cap(.import_source) } },
    } },
};

fn resolveContainers(classes: []const facts.ClassDef, methods: []facts.MethodDef, calls: []facts.Call) void {
    _ = classes;
    for (calls) |*c| {
        c.container = enclosingMethodContainer(methods, c.start) orelse "";
    }
}

fn enclosingMethodContainer(methods: []const facts.MethodDef, start: u32) ?[]const u8 {
    var best: ?usize = null;

    for (methods, 0..) |m, i| {
        if (m.start > start or start >= m.end) continue;
        if (best == null or methods[best.?].start < m.start) best = i;
    }

    return if (best) |i| methods[i].container else null;
}


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

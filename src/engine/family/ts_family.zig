const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const facts = @import("../facts.zig");
const family = @import("family.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.ts_family;
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
    .constructor_prefix = null,
    .relative_import_specifiers = true,
};

fn sym(comptime name: []const u8) u16 {
    return @intFromEnum(@field(kinds.Kind, name));
}

fn fld(comptime field: kinds.Field) u16 {
    return @intFromEnum(field);
}

const cap = facts.cap;

const fact_patterns: []const query.Pattern = &.{
    .{ .kind = .{ .symbol = sym("class_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.class_name) } },
    } },
    .{ .kind = .{ .symbol = sym("abstract_class_declaration") }, .capture = cap(.class_node), .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.class_name) } },
    } },
    .{ .kind = .{ .symbol = sym("method_definition") }, .capture = cap(.method_node), .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.method_name) } },
    } },
    .{ .kind = .{ .symbol = sym("public_field_definition") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .symbol = sym("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("required_parameter") }, .fields = &.{
        .{ .relation = .{ .field = fld(.pattern) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .symbol = sym("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("variable_declarator") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.type) }, .pattern = .{ .kind = .{ .symbol = sym("type_annotation") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("type_identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("variable_declarator") }, .fields = &.{
        .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_name) } },
        .{ .relation = .{ .field = fld(.value) }, .pattern = .{ .kind = .{ .symbol = sym("new_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.constructor) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("assignment_expression") }, .fields = &.{
        .{ .relation = .{ .field = fld(.left) }, .pattern = .{ .kind = .{ .symbol = sym("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.object) }, .pattern = .{ .kind = .{ .symbol = sym("this") } } },
            .{ .relation = .{ .field = fld(.property) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.decl_name) } },
        } } },
        .{ .relation = .{ .field = fld(.right) }, .pattern = .{ .kind = .{ .symbol = sym("new_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.constructor) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.decl_type) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = fld(.function) }, .pattern = .{ .kind = .{ .symbol = sym("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.object) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.call_receiver) } },
            .{ .relation = .{ .field = fld(.property) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("call_expression") }, .capture = cap(.call_node), .fields = &.{
        .{ .relation = .{ .field = fld(.function) }, .pattern = .{ .kind = .{ .symbol = sym("member_expression") }, .fields = &.{
            .{ .relation = .{ .field = fld(.object) }, .pattern = .{ .kind = .{ .symbol = sym("member_expression") }, .fields = &.{
                .{ .relation = .{ .field = fld(.object) }, .pattern = .{ .kind = .{ .symbol = sym("this") } } },
                .{ .relation = .{ .field = fld(.property) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.call_receiver) } },
            } } },
            .{ .relation = .{ .field = fld(.property) }, .pattern = .{ .kind = .{ .symbol = sym("property_identifier") }, .capture = cap(.call_method) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("import_statement") }, .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("import_clause") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("named_imports") }, .fields = &.{
                .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("import_specifier") }, .fields = &.{
                    .{ .relation = .{ .field = fld(.name) }, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.import_name) } },
                } } },
            } } },
        } } },
        .{ .relation = .{ .field = fld(.source) }, .pattern = .{ .kind = .{ .symbol = sym("string") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("string_fragment") }, .capture = cap(.import_source) } },
        } } },
    } },
    .{ .kind = .{ .symbol = sym("import_statement") }, .fields = &.{
        .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("import_clause") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("identifier") }, .capture = cap(.import_name) } },
        } } },
        .{ .relation = .{ .field = fld(.source) }, .pattern = .{ .kind = .{ .symbol = sym("string") }, .fields = &.{
            .{ .relation = .child, .pattern = .{ .kind = .{ .symbol = sym("string_fragment") }, .capture = cap(.import_source) } },
        } } },
    } },
};

fn resolveContainers(classes: []const facts.ClassDef, methods: []facts.MethodDef, calls: []facts.Call) void {
    for (methods) |*m| {
        if (m.container.len == 0) m.container = innermostClassName(classes, m.start, m.end) orelse "";
    }

    for (calls) |*c| {
        c.container = innermostClassName(classes, c.start, c.start) orelse "";
    }
}

fn innermostClassName(classes: []const facts.ClassDef, start: u32, end: u32) ?[]const u8 {
    var best: ?usize = null;

    for (classes, 0..) |cl, i| {
        if (cl.start > start or end > cl.end) continue;
        if (cl.start == start and cl.end == end) continue;
        if (best == null or classes[best.?].start < cl.start) best = i;
    }

    return if (best) |i| classes[i].name else null;
}

fn classifyMetric(k: kinds.Kind) ?metric.MetricKind {
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

fn paramCount(params: Node) u32 {
    return metric.countNonExtraNamed(params);
}

fn buildKindRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildKindRemap(grammar, gpa);
}

fn buildFieldRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildFieldRemap(grammar, gpa);
}

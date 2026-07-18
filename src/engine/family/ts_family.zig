const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const family = @import("family.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.ts_family;
const fields = family.FieldFns(kinds.Field);
const kind_fns = family.KindFns(kinds.Kind, &kinds.anon_names, kinds.anon_base);
const metric_table = family.MetricTable(kinds.Kind, kinds.kind_count, classifyMetric);

pub const adapter: family.Adapter = .{
    .supertypes = &kinds.supertypes,
    .kindName = kinds.name,
    .kindId = kind_fns.id,
    .fieldId = fields.id,
    .fieldName = fields.name,
    .buildKindRemap = buildKindRemap,
    .buildFieldRemap = buildFieldRemap,
    .buildMetricTable = metric_table.build,
    .contextKind = contextKind,
    .paramCount = paramCount,
    .fact_patterns = fact_patterns,
    .resolveContainers = resolveContainers,
    .constructor_prefix = null,
    .relative_import_specifiers = true,
};

fn sym(comptime name: []const u8) u16 {
    return @intFromEnum(@field(kinds.Kind, name));
}

fn fld(comptime field_: kinds.Field) u16 {
    return @intFromEnum(field_);
}

const cap = facts.cap;

fn pat(comptime name: []const u8) query.Pattern {
    return .{ .kind = .{ .symbol = sym(name) } };
}

fn patC(comptime name: []const u8, capture: query.CaptureId) query.Pattern {
    return .{ .kind = .{ .symbol = sym(name) }, .capture = capture };
}

fn patF(comptime name: []const u8, comptime fields_: []const query.Field) query.Pattern {
    return .{ .kind = .{ .symbol = sym(name) }, .fields = fields_ };
}

fn patCF(comptime name: []const u8, capture: query.CaptureId, comptime fields_: []const query.Field) query.Pattern {
    return .{ .kind = .{ .symbol = sym(name) }, .capture = capture, .fields = fields_ };
}

fn field(comptime name: kinds.Field, pattern: query.Pattern) query.Field {
    return .{ .relation = .{ .field = fld(name) }, .pattern = pattern };
}

fn child(pattern: query.Pattern) query.Field {
    return .{ .relation = .child, .pattern = pattern };
}

fn typeAnnotation(comptime capture: query.CaptureId) query.Pattern {
    return patF("type_annotation", &.{
        child(patC("type_identifier", capture)),
    });
}

const fact_patterns: []const query.Pattern = &.{
    patCF("class_declaration", cap(.class_node), &.{
        field(.name, patC("type_identifier", cap(.class_name))),
    }),
    patCF("abstract_class_declaration", cap(.class_node), &.{
        field(.name, patC("type_identifier", cap(.class_name))),
    }),
    patCF("method_definition", cap(.method_node), &.{
        field(.name, patC("property_identifier", cap(.method_name))),
    }),
    patF("public_field_definition", &.{
        field(.name, patC("property_identifier", cap(.decl_name))),
        field(.type, typeAnnotation(cap(.decl_type))),
    }),
    patF("required_parameter", &.{
        field(.pattern, patC("identifier", cap(.decl_name))),
        field(.type, typeAnnotation(cap(.decl_type))),
    }),
    patF("variable_declarator", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.type, typeAnnotation(cap(.decl_type))),
    }),
    patF("variable_declarator", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.value, patF("new_expression", &.{
            field(.constructor, patC("identifier", cap(.decl_type))),
        })),
    }),
    patF("assignment_expression", &.{
        field(.left, patF("member_expression", &.{
            field(.object, pat("this")),
            field(.property, patC("property_identifier", cap(.decl_name))),
        })),
        field(.right, patF("new_expression", &.{
            field(.constructor, patC("identifier", cap(.decl_type))),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("member_expression", &.{
            field(.object, patC("identifier", cap(.call_receiver))),
            field(.property, patC("property_identifier", cap(.call_method))),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("member_expression", &.{
            field(.object, patF("member_expression", &.{
                field(.object, pat("this")),
                field(.property, patC("property_identifier", cap(.call_receiver))),
            })),
            field(.property, patC("property_identifier", cap(.call_method))),
        })),
    }),
    patF("import_statement", &.{
        child(patF("import_clause", &.{
            child(patF("named_imports", &.{
                child(patF("import_specifier", &.{
                    field(.name, patC("identifier", cap(.import_name))),
                })),
            })),
        })),
        field(.source, patF("string", &.{
            child(patC("string_fragment", cap(.import_source))),
        })),
    }),
    patF("import_statement", &.{
        child(patF("import_clause", &.{
            child(patC("identifier", cap(.import_name))),
        })),
        field(.source, patF("string", &.{
            child(patC("string_fragment", cap(.import_source))),
        })),
    }),
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

fn contextKind(id: u16) ?diagnostic.ContextKind {
    const kind = std.enums.fromInt(kinds.Kind, id) orelse return null;

    return switch (kind) {
        .function_declaration,
        .function_expression,
        .generator_function_declaration,
        .generator_function,
        .arrow_function,
        => .function,
        .method_definition => .method,
        .class_declaration,
        .abstract_class_declaration,
        .interface_declaration,
        => .class,
        .internal_module,
        .module,
        => .namespace,
        else => null,
    };
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

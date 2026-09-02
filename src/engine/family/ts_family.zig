const std = @import("std");
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
const patterns = family.PatternFns(kinds.Kind, kinds.Field);
const pat = patterns.pat;
const patC = patterns.patC;
const patF = patterns.patF;
const patCF = patterns.patCF;
const field = patterns.field;
const child = patterns.child;
const cap = facts.cap;

pub const adapter: family.Adapter = .{
    .supertypes = &kinds.supertypes,
    .kind_count = kinds.kind_count,
    .kindName = kinds.name,
    .kindId = kind_fns.id,
    .fieldId = fields.id,
    .fieldName = fields.name,
    .buildKindRemap = kinds.buildKindRemap,
    .buildFieldRemap = kinds.buildFieldRemap,
    .buildMetricTable = metric_table.build,
    .logical_operators = &.{ "&&", "||", "??" },
    .contextKind = contextKind,
    .contextName = contextName,
    .extraContext = null,
    .paramCount = paramCount,
    .argCount = argCount,
    .fact_patterns = fact_patterns,
    .resolveContainers = family.resolveContainersByEnclosingClass,
    .constructor_prefix = null,
    .isRelativeImport = isRelativeImport,
};

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

fn isRelativeImport(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
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

fn contextName(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error![]const u8 {
    if (try family.nameFromField(allocator, node, source)) |name| return name;

    if (node.parent()) |parent| {
        if (std.mem.eql(u8, parent.kind(), "variable_declarator")) {
            if (try family.nameFromField(allocator, parent, source)) |name| return name;
        }
    }

    if (try family.nameFromFirstNamedChild(allocator, node, source)) |name| return name;

    return allocator.dupe(u8, "<anonymous>");
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

fn paramCount(node: Node) ?u32 {
    if (node.childByFieldName("parameters")) |params| return metric.countNonExtraNamed(params);
    if (node.childByFieldName("parameter") != null) return 1;
    return null;
}

fn argCount(node: Node) ?u32 {
    const arguments = node.childByFieldName("arguments") orelse return null;
    return metric.countNonExtraNamed(arguments);
}

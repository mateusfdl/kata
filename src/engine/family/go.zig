const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const family = @import("family.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.go;
const fields = family.FieldFns(kinds.Field);
const kind_fns = family.KindFns(kinds.Kind, &kinds.anon_names, kinds.anon_base);
const metric_table = family.MetricTable(kinds.Kind, kinds.kind_count, classifyMetric);

pub const adapter: family.Adapter = .{
    .supertypes = &kinds.supertypes,
    .kind_count = kinds.kind_count,
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
    .constructor_prefix = "New",
    .relative_import_specifiers = false,
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

fn either(comptime branches: []const query.Pattern) query.Pattern {
    return .{ .kind = .{ .alternation = branches } };
}

fn typeOrPointer(comptime capture: query.CaptureId) query.Pattern {
    return either(&.{
        patC("type_identifier", capture),
        patF("pointer_type", &.{
            child(patC("type_identifier", capture)),
        }),
    });
}

const fact_patterns: []const query.Pattern = &.{
    patCF("type_declaration", cap(.class_node), &.{
        child(patF("type_spec", &.{
            field(.name, patC("type_identifier", cap(.class_name))),
        })),
    }),
    patCF("method_declaration", cap(.method_node), &.{
        field(.receiver, patF("parameter_list", &.{
            child(patF("parameter_declaration", &.{
                field(.type, typeOrPointer(cap(.method_recv))),
            })),
        })),
        field(.name, patC("field_identifier", cap(.method_name))),
    }),
    patF("parameter_declaration", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.type, typeOrPointer(cap(.decl_type))),
    }),
    patF("field_declaration", &.{
        field(.name, patC("field_identifier", cap(.decl_name))),
        field(.type, typeOrPointer(cap(.decl_type))),
    }),
    patF("var_spec", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.type, typeOrPointer(cap(.decl_type))),
    }),
    patF("short_var_declaration", &.{
        field(.left, patF("expression_list", &.{
            child(patC("identifier", cap(.decl_name))),
        })),
        field(.right, patF("expression_list", &.{
            child(patF("call_expression", &.{
                field(.function, patC("identifier", cap(.decl_ctor))),
            })),
        })),
    }),
    patF("short_var_declaration", &.{
        field(.left, patF("expression_list", &.{
            child(patC("identifier", cap(.decl_name))),
        })),
        field(.right, patF("expression_list", &.{
            child(patF("composite_literal", &.{
                field(.type, patC("type_identifier", cap(.decl_type))),
            })),
        })),
    }),
    patF("short_var_declaration", &.{
        field(.left, patF("expression_list", &.{
            child(patC("identifier", cap(.decl_name))),
        })),
        field(.right, patF("expression_list", &.{
            child(patF("unary_expression", &.{
                field(.operand, patF("composite_literal", &.{
                    field(.type, patC("type_identifier", cap(.decl_type))),
                })),
            })),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("selector_expression", &.{
            field(.operand, patC("identifier", cap(.call_receiver))),
            field(.field, patC("field_identifier", cap(.call_method))),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("selector_expression", &.{
            field(.operand, patF("selector_expression", &.{
                field(.field, patC("field_identifier", cap(.call_receiver))),
            })),
            field(.field, patC("field_identifier", cap(.call_method))),
        })),
    }),
    patF("import_spec", &.{
        field(.path, patC("interpreted_string_literal", cap(.import_source))),
    }),
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

fn contextKind(id: u16) ?diagnostic.ContextKind {
    const kind = std.enums.fromInt(kinds.Kind, id) orelse return null;

    return switch (kind) {
        .function_declaration => .function,
        .method_declaration => .method,
        .type_declaration => .class,
        else => null,
    };
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

fn countFieldChildren(node: Node, field_: []const u8) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const name = node.fieldNameForChild(i) orelse continue;
        if (std.mem.eql(u8, name, field_)) count += 1;
    }
    return count;
}

fn buildKindRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildKindRemap(grammar, gpa);
}

fn buildFieldRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildFieldRemap(grammar, gpa);
}

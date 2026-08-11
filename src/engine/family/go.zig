const std = @import("std");
const node_kinds = @import("node_kinds");

const containing_interval = @import("shared").containing_interval;
const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const family = @import("family.zig");
const interval = @import("shared").interval;
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.go;
const fields = family.FieldFns(kinds.Field);
const kind_fns = family.KindFns(kinds.Kind, &kinds.anon_names, kinds.anon_base);
const metric_table = family.MetricTable(kinds.Kind, kinds.kind_count, classifyMetric);
const ByteInterval = interval.Type(u32, .half_open);
const MethodSelector = containing_interval.Selector(facts.MethodDef, ByteInterval, methodInterval);

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
    std.debug.assert(start < std.math.maxInt(u32));
    const index = MethodSelector.innermost(methods, .init(start, start + 1)) orelse return null;
    return methods[index].container;
}

fn methodInterval(method: facts.MethodDef) ByteInterval {
    return .init(method.start, method.end);
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
    var children = params.namedChildren();
    while (children.next()) |decl| {
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
    var children = node.children();
    while (children.next()) |candidate| {
        const name = candidate.fieldName() orelse continue;
        if (std.mem.eql(u8, name, field_)) count += 1;
    }
    return count;
}

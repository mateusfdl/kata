const std = @import("std");
const node_kinds = @import("node_kinds");

const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const family = @import("family.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const kinds = node_kinds.zig;
const fields = family.FieldFns(kinds.Field);
const kind_fns = family.KindFns(kinds.Kind, &kinds.anon_names, kinds.anon_base);
const metric_table = family.MetricTable(kinds.Kind, kinds.kind_count, classifyMetric);
const patterns = family.PatternFns(kinds.Kind, kinds.Field);
const sym = patterns.sym;
const pat = patterns.pat;
const patC = patterns.patC;
const patF = patterns.patF;
const patCF = patterns.patCF;
const field = patterns.field;
const child = patterns.child;
const first = patterns.first;
const either = patterns.either;
const eitherC = patterns.eitherC;
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
    .logical_operators = &.{ "and", "or", "orelse" },
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

fn bareTypeName(comptime capture: query.CaptureId) query.Pattern {
    return either(&.{
        patC("identifier", capture),
        patF("field_expression", &.{
            field(.member, patC("identifier", capture)),
        }),
    });
}

fn pointerTo(comptime capture: query.CaptureId) query.Pattern {
    return patF("pointer_type", &.{
        child(bareTypeName(capture)),
    });
}

fn typeName(comptime capture: query.CaptureId) query.Pattern {
    return either(&.{
        bareTypeName(capture),
        pointerTo(capture),
        patF("nullable_type", &.{
            child(either(&.{
                bareTypeName(capture),
                pointerTo(capture),
            })),
        }),
        patF("slice_type", &.{
            child(bareTypeName(capture)),
        }),
    });
}

fn importCall(comptime capture: query.CaptureId) query.Pattern {
    return patF("builtin_function", &.{
        child(.{ .kind = .{ .symbol = sym("builtin_identifier") }, .text = "@import" }),
        child(patF("arguments", &.{
            child(patF("string", &.{
                child(patC("string_content", capture)),
            })),
        })),
    });
}

const fact_patterns: []const query.Pattern = &.{
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.class_name))),
        child(eitherC(&.{
            pat("struct_declaration"),
            pat("enum_declaration"),
            pat("union_declaration"),
            pat("opaque_declaration"),
        }, cap(.class_node))),
    }),
    patCF("function_declaration", cap(.method_node), &.{
        field(.name, patC("identifier", cap(.method_name))),
    }),
    patF("parameter", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.type, typeName(cap(.decl_type))),
    }),
    patF("container_field", &.{
        field(.name, patC("identifier", cap(.decl_name))),
        field(.type, typeName(cap(.decl_type))),
    }),
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.decl_name))),
        field(.type, typeName(cap(.decl_type))),
    }),
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.decl_name))),
        child(patF("struct_initializer", &.{
            child(bareTypeName(cap(.decl_type))),
        })),
    }),
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.decl_name))),
        child(patF("unary_expression", &.{
            field(.argument, patF("struct_initializer", &.{
                child(bareTypeName(cap(.decl_type))),
            })),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("field_expression", &.{
            field(.object, patC("identifier", cap(.call_receiver))),
            field(.member, patC("identifier", cap(.call_method))),
        })),
    }),
    patCF("call_expression", cap(.call_node), &.{
        field(.function, patF("field_expression", &.{
            field(.object, patF("field_expression", &.{
                field(.object, .{ .kind = .{ .symbol = sym("identifier") }, .text = "self" }),
                field(.member, patC("identifier", cap(.call_receiver))),
            })),
            field(.member, patC("identifier", cap(.call_method))),
        })),
    }),
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.import_name))),
        child(importCall(cap(.import_source))),
    }),
    patF("variable_declaration", &.{
        first(patC("identifier", cap(.import_name))),
        child(patF("field_expression", &.{
            field(.object, importCall(cap(.import_source))),
        })),
    }),
};

fn isRelativeImport(specifier: []const u8) bool {
    return std.mem.endsWith(u8, specifier, ".zig");
}

fn contextKind(id: u16) ?diagnostic.ContextKind {
    const kind = std.enums.fromInt(kinds.Kind, id) orelse return null;

    return switch (kind) {
        .function_declaration,
        .test_declaration,
        => .function,
        .struct_declaration,
        .enum_declaration,
        .union_declaration,
        .opaque_declaration,
        => .class,
        else => null,
    };
}

fn contextName(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error![]const u8 {
    if (try family.nameFromField(allocator, node, source)) |name| return name;
    if (try containerName(allocator, node, source)) |name| return name;
    if (try testName(allocator, node, source)) |name| return name;

    return allocator.dupe(u8, "<anonymous>");
}

fn containerName(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (!isContainer(node)) return null;
    const parent = node.parent() orelse return null;
    if (!isKind(parent, .variable_declaration)) return null;
    const identifier = firstNamedChildOfKind(parent, .identifier) orelse return null;
    const text = identifier.text(source) orelse return null;

    return try allocator.dupe(u8, text);
}

fn testName(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (!isKind(node, .test_declaration)) return null;
    const name = node.namedChild(0) orelse return null;
    const text = name.text(source) orelse return null;

    return try allocator.dupe(u8, stripDoubleQuotes(text));
}

fn stripDoubleQuotes(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    if (text[0] != '"' or text[text.len - 1] != '"') return text;
    return text[1 .. text.len - 1];
}

fn isContainer(node: Node) bool {
    const kind = std.enums.fromInt(kinds.Kind, node.kindId()) orelse return false;
    return switch (kind) {
        .struct_declaration,
        .enum_declaration,
        .union_declaration,
        .opaque_declaration,
        => true,
        else => false,
    };
}

fn isKind(node: Node, kind: kinds.Kind) bool {
    return node.kindId() == @intFromEnum(kind);
}

fn firstNamedChildOfKind(node: Node, kind: kinds.Kind) ?Node {
    var children = node.namedChildren();
    while (children.next()) |candidate| {
        if (isKind(candidate, kind)) return candidate;
    }
    return null;
}

fn paramCount(node: Node) ?u32 {
    const parameters = firstNamedChildOfKind(node, .parameters) orelse return null;
    var count: u32 = 0;
    var children = parameters.namedChildren();
    while (children.next()) |candidate| {
        if (isKind(candidate, .parameter)) count += 1;
    }
    return count;
}

fn argCount(node: Node) ?u32 {
    const kind = std.enums.fromInt(kinds.Kind, node.kindId()) orelse return null;
    return switch (kind) {
        .call_expression => callArgCount(node),
        .builtin_function => builtinArgCount(node),
        else => null,
    };
}

fn callArgCount(node: Node) ?u32 {
    _ = node.childByFieldName("function") orelse return null;
    return metric.countNonExtraNamed(node) - 1;
}

fn builtinArgCount(node: Node) ?u32 {
    const arguments = firstNamedChildOfKind(node, .arguments) orelse return null;
    return metric.countNonExtraNamed(arguments);
}

fn classifyMetric(kind: kinds.Kind) ?metric.MetricKind {
    return switch (kind) {
        .function_declaration,
        .test_declaration,
        => .function,
        .if_statement => .branch,
        .if_expression => .ternary,
        .while_statement,
        .while_expression,
        .for_statement,
        .for_expression,
        => .loop,
        .switch_expression => .switch_stmt,
        .switch_case => .case,
        .catch_expression => .catch_clause,
        .binary_expression => .bool_op,
        else => null,
    };
}

const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const containing_interval = @import("shared").containing_interval;
const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const interval = @import("shared").interval;
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

const ByteInterval = interval.Type(u32, .half_open);
const ClassSelector = containing_interval.Selector(facts.ClassDef, ByteInterval, classInterval);

pub const Family = enum {
    ts_family,
    go,
};

pub fn of(fam: Family) *const Adapter {
    return switch (fam) {
        .ts_family => &@import("ts_family.zig").adapter,
        .go => &@import("go.zig").adapter,
    };
}

pub const Adapter = struct {
    supertypes: []const node_kinds.Supertype,
    kind_count: u16,
    kindName: *const fn (id: u16) []const u8,
    kindId: *const fn (name: []const u8, named: bool) u16,
    fieldId: *const fn (name: []const u8) u16,
    fieldName: *const fn (id: u16) ?[]const u8,
    buildKindRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
    buildFieldRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
    buildMetricTable: *const fn (gpa: std.mem.Allocator) std.mem.Allocator.Error![]?metric.MetricKind,
    logical_operators: []const []const u8,
    contextKind: *const fn (id: u16) ?diagnostic.ContextKind,
    contextName: *const fn (allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error![]const u8,
    extraContext: ?*const fn (allocator: std.mem.Allocator, node: Node, kind: diagnostic.ContextKind, source: []const u8) std.mem.Allocator.Error!?diagnostic.Context,
    paramCount: *const fn (node: Node) ?u32,
    argCount: *const fn (node: Node) ?u32,
    fact_patterns: []const query.Pattern,
    resolveContainers: *const fn (classes: []const facts.ClassDef, methods: []facts.MethodDef, calls: []facts.Call) void,
    constructor_prefix: ?[]const u8,
    isRelativeImport: *const fn (specifier: []const u8) bool,
};

pub fn neverRelativeImport(specifier: []const u8) bool {
    _ = specifier;
    return false;
}

pub fn resolveContainersByEnclosingClass(classes: []const facts.ClassDef, methods: []facts.MethodDef, calls: []facts.Call) void {
    for (methods) |*method| {
        if (method.container.len == 0) method.container = innermostClassName(classes, method.start, method.end) orelse "";
    }

    for (calls) |*call| {
        std.debug.assert(call.start < std.math.maxInt(u32));
        call.container = innermostClassName(classes, call.start, call.start + 1) orelse "";
    }
}

fn innermostClassName(classes: []const facts.ClassDef, start: u32, end: u32) ?[]const u8 {
    const index = ClassSelector.innermost(classes, .init(start, end)) orelse return null;
    return classes[index].name;
}

fn classInterval(class: facts.ClassDef) ByteInterval {
    return .init(class.start, class.end);
}

pub fn nameFromField(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const name = node.childByFieldName("name") orelse return null;
    const text = name.text(source) orelse return null;

    return try allocator.dupe(u8, text);
}

pub fn nameFromFirstNamedChild(allocator: std.mem.Allocator, node: Node, source: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const first_child = node.namedChild(0) orelse return null;

    return nameFromField(allocator, first_child, source);
}

/// indexed by kata kind id: the enum field value is the id, so the table is a
/// pure compile-time projection of the classifier over the family's named kinds
/// the anonymous range stays null (no metric is an anonymous token).
pub fn MetricTable(
    comptime Kind: type,
    comptime size: u16,
    comptime classifyKind: fn (Kind) ?metric.MetricKind,
) type {
    return struct {
        pub fn build(gpa: std.mem.Allocator) std.mem.Allocator.Error![]?metric.MetricKind {
            const table = try gpa.alloc(?metric.MetricKind, size);
            @memset(table, null);

            inline for (@typeInfo(Kind).@"enum".fields) |f| {
                if (f.value != 0) {
                    if (classifyKind(@enumFromInt(f.value))) |mk| table[f.value] = mk;
                }
            }

            return table;
        }
    };
}

pub fn PatternFns(comptime Kind: type, comptime Field: type) type {
    return struct {
        pub fn sym(comptime name: []const u8) u16 {
            return @intFromEnum(@field(Kind, name));
        }

        pub fn fld(comptime field_: Field) u16 {
            return @intFromEnum(field_);
        }

        pub fn pat(comptime name: []const u8) query.Pattern {
            return .{ .kind = .{ .symbol = sym(name) } };
        }

        pub fn patC(comptime name: []const u8, capture: query.CaptureId) query.Pattern {
            return .{ .kind = .{ .symbol = sym(name) }, .capture = capture };
        }

        pub fn patF(comptime name: []const u8, comptime fields: []const query.Field) query.Pattern {
            return .{ .kind = .{ .symbol = sym(name) }, .fields = fields };
        }

        pub fn patCF(comptime name: []const u8, capture: query.CaptureId, comptime fields: []const query.Field) query.Pattern {
            return .{ .kind = .{ .symbol = sym(name) }, .capture = capture, .fields = fields };
        }

        pub fn field(comptime name: Field, pattern: query.Pattern) query.Field {
            return .{ .relation = .{ .field = fld(name) }, .pattern = pattern };
        }

        pub fn child(pattern: query.Pattern) query.Field {
            return .{ .relation = .child, .pattern = pattern };
        }

        pub fn first(pattern: query.Pattern) query.Field {
            return .{ .relation = .first_child, .pattern = pattern };
        }

        pub fn either(comptime branches: []const query.Pattern) query.Pattern {
            return .{ .kind = .{ .alternation = branches } };
        }

        pub fn eitherC(comptime branches: []const query.Pattern, capture: query.CaptureId) query.Pattern {
            return .{ .kind = .{ .alternation = branches }, .capture = capture };
        }
    };
}

pub fn KindFns(
    comptime Kind: type,
    comptime anon_names: []const []const u8,
    comptime anon_base: u16,
) type {
    return struct {
        pub fn id(name: []const u8, named: bool) u16 {
            if (named) {
                return if (std.meta.stringToEnum(Kind, name)) |k| @intFromEnum(k) else 0;
            }
            for (anon_names, 0..) |token, i| {
                if (std.mem.eql(u8, token, name)) return anon_base + @as(u16, @intCast(i));
            }
            return 0;
        }
    };
}

pub fn FieldFns(comptime Field: type) type {
    return struct {
        pub fn id(field_name: []const u8) u16 {
            return if (std.meta.stringToEnum(Field, field_name)) |f| @intFromEnum(f) else 0;
        }

        pub fn name(field_id: u16) ?[]const u8 {
            if (field_id == 0) return null;
            return @tagName(@as(Field, @enumFromInt(field_id)));
        }
    };
}

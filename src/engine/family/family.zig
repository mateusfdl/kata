const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const facts = @import("../facts.zig");
const metric = @import("../metric.zig");
const query = @import("../query.zig");
const Node = @import("../node.zig").Node;

pub const Family = enum {
    ts_family,
    go,
};

pub const Adapter = struct {
    supertypes: []const node_kinds.Supertype,
    kindName: *const fn (id: u16) []const u8,
    kindId: *const fn (name: []const u8, named: bool) u16,
    fieldId: *const fn (name: []const u8) u16,
    fieldName: *const fn (id: u16) ?[]const u8,
    buildKindRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
    buildFieldRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
    buildMetricTable: *const fn (gpa: std.mem.Allocator) std.mem.Allocator.Error![]?metric.MetricKind,
    paramCount: *const fn (params: Node) u32,
    fact_patterns: []const query.Pattern,
    resolveContainers: *const fn (classes: []const facts.ClassDef, methods: []facts.MethodDef, calls: []facts.Call) void,
    constructor_prefix: ?[]const u8,
    relative_import_specifiers: bool,
};

pub fn of(fam: Family) *const Adapter {
    return switch (fam) {
        .ts_family => &@import("ts_family.zig").adapter,
        .go => &@import("go.zig").adapter,
    };
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

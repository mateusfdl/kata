const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

pub const Family = enum {
    ts_family,
    go,
};

pub const Adapter = struct {
    supertypes: []const node_kinds.Supertype,
    kindName: *const fn (id: u16) []const u8,
    fieldId: *const fn (name: []const u8) u16,
    fieldName: *const fn (id: u16) ?[]const u8,
    buildKindRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
    buildFieldRemap: *const fn (grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16,
};

pub fn of(fam: Family) *const Adapter {
    return switch (fam) {
        .ts_family => &@import("ts_family.zig").adapter,
        .go => &@import("go.zig").adapter,
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

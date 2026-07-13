const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");

const family = @import("family.zig");

const kinds = node_kinds.ts_family;
const fields = family.FieldFns(kinds.Field);

pub const adapter: family.Adapter = .{
    .supertypes = &kinds.supertypes,
    .kindName = kinds.name,
    .fieldId = fields.id,
    .fieldName = fields.name,
    .buildKindRemap = buildKindRemap,
    .buildFieldRemap = buildFieldRemap,
};

fn buildKindRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildKindRemap(grammar, gpa);
}

fn buildFieldRemap(grammar: *const ts.Language, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return kinds.buildFieldRemap(grammar, gpa);
}

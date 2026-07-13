const std = @import("std");
const ts = @import("tree_sitter");

const family_mod = @import("family/family.zig");

/// Per-grammar remap tables from tree-sitter symbol/field ids to kata ids, built
/// once per language and cached by the engine. The converter applies them so the
/// flat `Ast` stores kata ids directly.
pub const Kinds = struct {
    kind_remap: []const u16,
    field_remap: []const u16,
};

pub fn build(
    fam: family_mod.Family,
    grammar: *const ts.Language,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!Kinds {
    const adapter = family_mod.of(fam);
    const kind_remap = try adapter.buildKindRemap(grammar, gpa);
    errdefer gpa.free(kind_remap);
    const field_remap = try adapter.buildFieldRemap(grammar, gpa);
    return .{ .kind_remap = kind_remap, .field_remap = field_remap };
}

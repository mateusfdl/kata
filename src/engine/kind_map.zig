const std = @import("std");
const ts = @import("tree_sitter");

const node_kinds = @import("node_kinds");
const language = @import("language.zig");

/// Per-grammar remap tables from tree-sitter symbol/field ids to kata ids, built
/// once per language and cached by the engine. The converter applies them so the
/// flat `Ast` stores kata ids directly.
pub const Kinds = struct {
    kind_remap: []const u16,
    field_remap: []const u16,
};

pub fn supertypes(lang: language.Name) []const node_kinds.Supertype {
    return switch (lang) {
        .ts, .tsx => &node_kinds.ts_family.supertypes,
        .go => &node_kinds.go.supertypes,
    };
}

pub fn build(
    lang: language.Name,
    grammar: *const ts.Language,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!Kinds {
    const kind_remap = try buildKindRemap(lang, grammar, gpa);
    errdefer gpa.free(kind_remap);
    const field_remap = try buildFieldRemap(lang, grammar, gpa);
    return .{ .kind_remap = kind_remap, .field_remap = field_remap };
}

fn buildKindRemap(lang: language.Name, grammar: *const ts.Language, gpa: std.mem.Allocator) ![]u16 {
    return switch (lang) {
        .ts, .tsx => node_kinds.ts_family.buildKindRemap(grammar, gpa),
        .go => node_kinds.go.buildKindRemap(grammar, gpa),
    };
}

fn buildFieldRemap(lang: language.Name, grammar: *const ts.Language, gpa: std.mem.Allocator) ![]u16 {
    return switch (lang) {
        .ts, .tsx => node_kinds.ts_family.buildFieldRemap(grammar, gpa),
        .go => node_kinds.go.buildFieldRemap(grammar, gpa),
    };
}

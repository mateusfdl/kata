const std = @import("std");
const ts = @import("tree_sitter");

const node = @import("node.zig");
const node_kinds = @import("node_kinds");
const language = @import("language.zig");

pub fn build(
    lang: language.Name,
    grammar: *const ts.Language,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!node.Kinds {
    const remap = switch (lang) {
        .ts, .tsx => try node_kinds.ts_family.buildKindRemap(grammar, gpa),
        .go => try node_kinds.go.buildKindRemap(grammar, gpa),
    };
    return .{ .kind_remap = remap };
}

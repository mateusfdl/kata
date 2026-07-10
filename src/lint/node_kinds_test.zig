const std = @import("std");
const nk = @import("node_kinds");

const language = @import("language.zig");

fn anonId(comptime family: type, token: []const u8) u16 {
    for (family.anon_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, token)) return family.anon_base + @as(u16, @intCast(i));
    }
    unreachable;
}

test "node_kinds: id-space layout per family" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(nk.ts_family.Kind.unknown));
    try std.testing.expectEqual(@as(u16, 185), nk.ts_family.named_count);
    try std.testing.expectEqual(@as(u16, 186), nk.ts_family.anon_base);
    try std.testing.expectEqual(@as(u16, 186 + 143), nk.ts_family.kind_count);
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(nk.go.Kind.unknown));
    try std.testing.expectEqual(@as(u16, 106), nk.go.named_count);
    try std.testing.expectEqual(@as(u16, 107), nk.go.anon_base);
    try std.testing.expectEqual(@as(u16, 107 + 76), nk.go.kind_count);
}

test "node_kinds: name routes to kind_names and anon_names" {
    try std.testing.expectEqualStrings("ERROR", nk.ts_family.name(0));
    try std.testing.expectEqualStrings("program", nk.ts_family.name(@intFromEnum(nk.ts_family.Kind.program)));
    try std.testing.expectEqualStrings("&&", nk.ts_family.name(anonId(nk.ts_family, "&&")));
    try std.testing.expectEqualStrings("ERROR", nk.ts_family.name(nk.ts_family.kind_count));
    try std.testing.expectEqualStrings("source_file", nk.go.name(@intFromEnum(nk.go.Kind.source_file)));
}

test "node_kinds: ts kind remap maps grammar symbols to kata ids" {
    const grammar = language.grammar(.ts);
    const remap = try nk.ts_family.buildKindRemap(grammar, std.testing.allocator);
    defer std.testing.allocator.free(remap);

    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Kind.program), remap[grammar.idForNodeKind("program", true)]);
    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Kind.identifier), remap[grammar.idForNodeKind("identifier", true)]);
    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Kind.type_assertion), remap[grammar.idForNodeKind("type_assertion", true)]);
}

test "node_kinds: ts and tsx remaps agree on shared kinds and skip absent ones" {
    const ts_grammar = language.grammar(.ts);
    const tsx_grammar = language.grammar(.tsx);
    const ts_remap = try nk.ts_family.buildKindRemap(ts_grammar, std.testing.allocator);
    defer std.testing.allocator.free(ts_remap);
    const tsx_remap = try nk.ts_family.buildKindRemap(tsx_grammar, std.testing.allocator);
    defer std.testing.allocator.free(tsx_remap);

    try std.testing.expectEqual(
        ts_remap[ts_grammar.idForNodeKind("identifier", true)],
        tsx_remap[tsx_grammar.idForNodeKind("identifier", true)],
    );
    try std.testing.expectEqual(@as(u16, 0), tsx_grammar.idForNodeKind("type_assertion", true));
    try std.testing.expectEqual(@as(u16, 0), tsx_remap[0]);
    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Kind.jsx_element), tsx_remap[tsx_grammar.idForNodeKind("jsx_element", true)]);
    try std.testing.expectEqual(@as(u16, 0), ts_grammar.idForNodeKind("jsx_element", true));
}

test "node_kinds: anonymous tokens remap to the anon id range" {
    const grammar = language.grammar(.ts);
    const remap = try nk.ts_family.buildKindRemap(grammar, std.testing.allocator);
    defer std.testing.allocator.free(remap);

    try std.testing.expectEqual(anonId(nk.ts_family, "&&"), remap[grammar.idForNodeKind("&&", false)]);
    try std.testing.expectEqual(anonId(nk.ts_family, "||"), remap[grammar.idForNodeKind("||", false)]);
    try std.testing.expectEqual(anonId(nk.ts_family, "??"), remap[grammar.idForNodeKind("??", false)]);
}

test "node_kinds: field remap maps grammar field ids to kata field ids" {
    const grammar = language.grammar(.ts);
    const remap = try nk.ts_family.buildFieldRemap(grammar, std.testing.allocator);
    defer std.testing.allocator.free(remap);

    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(nk.ts_family.Field.none));
    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Field.name), remap[grammar.fieldIdForName("name")]);
    try std.testing.expectEqual(@intFromEnum(nk.ts_family.Field.value), remap[grammar.fieldIdForName("value")]);
}

test "node_kinds: go remap is its own id space" {
    const grammar = language.grammar(.go);
    const remap = try nk.go.buildKindRemap(grammar, std.testing.allocator);
    defer std.testing.allocator.free(remap);

    try std.testing.expectEqual(@intFromEnum(nk.go.Kind.short_var_declaration), remap[grammar.idForNodeKind("short_var_declaration", true)]);
    try std.testing.expectEqual(anonId(nk.go, "&&"), remap[grammar.idForNodeKind("&&", false)]);
}

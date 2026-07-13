const std = @import("std");

const node_kinds = @import("node_kinds");

const family = @import("family/family.zig");

test "family: kindId resolves named kinds to kata enum ids" {
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.ts_family.Kind.call_expression),
        family.of(.ts_family).kindId("call_expression", true),
    );
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.go.Kind.function_declaration),
        family.of(.go).kindId("function_declaration", true),
    );
}

test "family: kindId resolves anonymous tokens into the anon range" {
    const ts_id = family.of(.ts_family).kindId("&&", false);
    try std.testing.expectEqual(true, ts_id >= node_kinds.ts_family.anon_base);
    try std.testing.expectEqualStrings("&&", node_kinds.ts_family.name(ts_id));

    const go_id = family.of(.go).kindId("&&", false);
    try std.testing.expectEqual(true, go_id >= node_kinds.go.anon_base);
    try std.testing.expectEqualStrings("&&", node_kinds.go.name(go_id));
}

test "family: kindId returns zero for unknown names" {
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("not_a_real_node_kind", true));
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("not_a_real_token", false));
    try std.testing.expectEqual(@as(u16, 0), family.of(.go).kindId("not_a_real_node_kind", true));
}

test "family: kindId is strict about namedness" {
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("identifier", false));
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("&&", true));
}

test "family: kindId resolves dialect specific kinds family wide" {
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.ts_family.Kind.jsx_element),
        family.of(.ts_family).kindId("jsx_element", true),
    );
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.ts_family.Kind.type_assertion),
        family.of(.ts_family).kindId("type_assertion", true),
    );
}

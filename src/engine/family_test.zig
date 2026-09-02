const std = @import("std");

const node_kinds = @import("node_kinds");

const family = @import("family/family.zig");

test "family: adapters expose exact logical operator lists" {
    const ts_expected = [_][]const u8{ "&&", "||", "??" };
    const go_expected = [_][]const u8{ "&&", "||" };
    const zig_expected = [_][]const u8{ "and", "or", "orelse" };

    const ts_actual = family.of(.ts_family).logical_operators;
    try std.testing.expectEqual(ts_expected.len, ts_actual.len);
    for (ts_expected, ts_actual) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const go_actual = family.of(.go).logical_operators;
    try std.testing.expectEqual(go_expected.len, go_actual.len);
    for (go_expected, go_actual) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const zig_actual = family.of(.zig).logical_operators;
    try std.testing.expectEqual(zig_expected.len, zig_actual.len);
    for (zig_expected, zig_actual) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

test "family: adapters classify relative import specifiers" {
    const Case = struct { specifier: []const u8, ts: bool, go: bool, zig: bool };
    const cases = [_]Case{
        .{ .specifier = "./a", .ts = true, .go = false, .zig = false },
        .{ .specifier = "../a", .ts = true, .go = false, .zig = false },
        .{ .specifier = "./a.zig", .ts = true, .go = false, .zig = true },
        .{ .specifier = "../infra/db.zig", .ts = true, .go = false, .zig = true },
        .{ .specifier = "sibling.zig", .ts = false, .go = false, .zig = true },
        .{ .specifier = "infra/db.zig", .ts = false, .go = false, .zig = true },
        .{ .specifier = "std", .ts = false, .go = false, .zig = false },
        .{ .specifier = "github.com/x/y", .ts = false, .go = false, .zig = false },
        .{ .specifier = "", .ts = false, .go = false, .zig = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.ts, family.of(.ts_family).isRelativeImport(case.specifier));
        try std.testing.expectEqual(case.go, family.of(.go).isRelativeImport(case.specifier));
        try std.testing.expectEqual(case.zig, family.of(.zig).isRelativeImport(case.specifier));
    }
}

test "family: kindId resolves named kinds to kata enum ids" {
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.ts_family.Kind.call_expression),
        family.of(.ts_family).kindId("call_expression", true),
    );
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.go.Kind.function_declaration),
        family.of(.go).kindId("function_declaration", true),
    );
    try std.testing.expectEqual(
        @intFromEnum(node_kinds.zig.Kind.function_declaration),
        family.of(.zig).kindId("function_declaration", true),
    );
}

test "family: kindId resolves anonymous tokens into the anon range" {
    const ts_id = family.of(.ts_family).kindId("&&", false);
    try std.testing.expectEqual(true, ts_id >= node_kinds.ts_family.anon_base);
    try std.testing.expectEqualStrings("&&", node_kinds.ts_family.name(ts_id));

    const go_id = family.of(.go).kindId("&&", false);
    try std.testing.expectEqual(true, go_id >= node_kinds.go.anon_base);
    try std.testing.expectEqualStrings("&&", node_kinds.go.name(go_id));

    const zig_id = family.of(.zig).kindId("and", false);
    try std.testing.expectEqual(true, zig_id >= node_kinds.zig.anon_base);
    try std.testing.expectEqualStrings("and", node_kinds.zig.name(zig_id));
}

test "family: kindId returns zero for unknown names" {
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("not_a_real_node_kind", true));
    try std.testing.expectEqual(@as(u16, 0), family.of(.ts_family).kindId("not_a_real_token", false));
    try std.testing.expectEqual(@as(u16, 0), family.of(.go).kindId("not_a_real_node_kind", true));
    try std.testing.expectEqual(@as(u16, 0), family.of(.zig).kindId("not_a_real_node_kind", true));
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

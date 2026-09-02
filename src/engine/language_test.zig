const std = @import("std");

const family = @import("family/family.zig");
const language = @import("language.zig");

test "Name.fromString / toString round-trip" {
    try std.testing.expectEqual(@as(?language.Name, .ts), language.Name.fromString("ts"));
    try std.testing.expectEqual(@as(?language.Name, .tsx), language.Name.fromString("tsx"));
    try std.testing.expectEqual(@as(?language.Name, .go), language.Name.fromString("go"));
    try std.testing.expectEqual(@as(?language.Name, .zig), language.Name.fromString("zig"));
    try std.testing.expectEqual(@as(?language.Name, null), language.Name.fromString("python"));

    try std.testing.expectEqualStrings("ts", language.Name.toString(.ts));
    try std.testing.expectEqualStrings("tsx", language.Name.toString(.tsx));
    try std.testing.expectEqualStrings("go", language.Name.toString(.go));
    try std.testing.expectEqualStrings("zig", language.Name.toString(.zig));
}

test "grammar resolves distinct pointers per language" {
    const a = language.grammar(.ts);
    const b = language.grammar(.ts);
    try std.testing.expect(a == b);

    const c = language.grammar(.tsx);
    try std.testing.expect(a != c);

    const d = language.grammar(.go);
    try std.testing.expect(c != d);

    const e = language.grammar(.zig);
    try std.testing.expect(d != e);
}

test "supported lists name every language" {
    try std.testing.expectEqualStrings("ts, tsx, go, or zig", language.supported_list);
    try std.testing.expectEqualStrings("ts|tsx|go|zig", language.pipe_list);
}

test "family collapses ts and tsx into ts_family" {
    try std.testing.expectEqual(family.Family.ts_family, language.Name.ts.family());
    try std.testing.expectEqual(family.Family.ts_family, language.Name.tsx.family());
    try std.testing.expectEqual(family.Family.go, language.Name.go.family());
    try std.testing.expectEqual(family.Family.zig, language.Name.zig.family());
}

test "Name.fromExtension resolves zig" {
    try std.testing.expectEqual(@as(?language.Name, .zig), language.Name.fromExtension(".zig"));
}

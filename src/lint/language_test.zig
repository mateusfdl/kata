const std = @import("std");
const language = @import("language.zig");

test "Name.fromString / toString round-trip" {
    try std.testing.expectEqual(@as(?language.Name, .ts), language.Name.fromString("ts"));
    try std.testing.expectEqual(@as(?language.Name, .tsx), language.Name.fromString("tsx"));
    try std.testing.expectEqual(@as(?language.Name, .go), language.Name.fromString("go"));
    try std.testing.expectEqual(@as(?language.Name, null), language.Name.fromString("python"));

    try std.testing.expectEqualStrings("ts", language.Name.toString(.ts));
    try std.testing.expectEqualStrings("tsx", language.Name.toString(.tsx));
    try std.testing.expectEqualStrings("go", language.Name.toString(.go));
}

test "Registry resolves distinct grammar pointers per language" {
    var r = language.Registry.init();

    const a = r.get(.ts);
    const b = r.get(.ts);
    try std.testing.expect(a == b);

    const c = r.get(.tsx);
    try std.testing.expect(a != c);

    const d = r.get(.go);
    try std.testing.expect(c != d);
}

test "supported_list names every language" {
    try std.testing.expectEqualStrings("ts, tsx, or go", language.supported_list);
}

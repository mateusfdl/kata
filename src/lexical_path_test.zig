const std = @import("std");

const lexical_path = @import("lexical_path.zig");

test "normalizeRelative applies dot segments with a stack" {
    const normalized = (try lexical_path.normalizeRelative(
        std.testing.allocator,
        "src/domain/orders",
        "../shared/./model",
    )).?;
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("src/domain/shared/model", normalized);
}

test "normalizeRelative rejects a path that escapes its lexical root" {
    try std.testing.expectEqual(
        null,
        try lexical_path.normalizeRelative(std.testing.allocator, "src", "../../outside"),
    );
}

test "resolveRelativeToFile starts at the file parent" {
    const normalized = (try lexical_path.resolveRelativeToFile(
        std.testing.allocator,
        "src/domain/order.ts",
        "../infra/../shared/db",
    )).?;
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("src/shared/db", normalized);
}

test "resolveRelativeToFile supports a file at the root" {
    const normalized = (try lexical_path.resolveRelativeToFile(
        std.testing.allocator,
        "main.ts",
        "./shared/db",
    )).?;
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("shared/db", normalized);
}

test "resolveRelativeToFile preserves an absolute root" {
    const normalized = (try lexical_path.resolveRelativeToFile(
        std.testing.allocator,
        "/repo/src/order.ts",
        "../shared/db",
    )).?;
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("/repo/shared/db", normalized);
}

test "resolveRelativeToFile preserves the root for a root file" {
    const normalized = (try lexical_path.resolveRelativeToFile(
        std.testing.allocator,
        "/main.ts",
        "./shared/db",
    )).?;
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("/shared/db", normalized);
}

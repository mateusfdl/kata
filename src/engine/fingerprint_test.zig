const std = @import("std");

const fingerprint = @import("fingerprint.zig");

test "fingerprint: normalize collapses whitespace runs" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "value", .expected = "value" },
        .{ .input = "  value  ", .expected = "value" },
        .{ .input = "left\t\tright", .expected = "left right" },
        .{ .input = "left\n\nright", .expected = "left right" },
        .{ .input = " \tleft\r\n \tright\n", .expected = "left right" },
        .{ .input = " \t\r\n", .expected = "" },
        .{ .input = "", .expected = "" },
    };

    for (cases) |case| {
        const normalized = try fingerprint.normalize(std.testing.allocator, case.input);
        defer std.testing.allocator.free(normalized);

        try std.testing.expectEqualStrings(case.expected, normalized);
    }
}

test "fingerprint: normalize preserves non UTF-8 bytes" {
    const input = [_]u8{ 0xff, ' ', ' ', 0x80 };
    const expected = [_]u8{ 0xff, ' ', 0x80 };
    const normalized = try fingerprint.normalize(std.testing.allocator, &input);
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualSlices(u8, &expected, normalized);
}

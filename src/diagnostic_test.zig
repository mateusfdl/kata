const std = @import("std");
const diagnostic = @import("diagnostic.zig");

test "Diagnostic JSON field names compliance" {
    const gpa = std.testing.allocator;

    const d: diagnostic.Diagnostic = .{
        .rule_id = "no-as-any",
        .language = "ts",
        .severity = "error",
        .message = "as any is not allowed",
        .range = .{
            .start = .{ .line = 0, .column = 11 },
            .end = .{ .line = 0, .column = 24 },
        },
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(d, .{}, &out.writer);

    const s = out.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "\"rule_id\":\"no-as-any\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"language\":\"ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"severity\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"message\":\"as any is not allowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"range\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"start\":{\"line\":0,\"column\":11}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"end\":{\"line\":0,\"column\":24}") != null);
}

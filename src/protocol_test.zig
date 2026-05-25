const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const protocol = @import("protocol.zig");
const test_frame = @import("test_frame.zig");

test "protocol: request round-trips with all fields" {
    const gpa = std.testing.allocator;

    const req: protocol.Request = .{
        .binary_mtime = 1726000000123,
        .language = "ts",
        .filename = "/tmp/foo.ts",
        .source = "const x = 1;\nconst y = 2;\n",
    };

    const bytes = try test_frame.frame(gpa, req);
    defer gpa.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try protocol.decode(protocol.Request, gpa, &reader);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1726000000123), parsed.value.binary_mtime);
    try std.testing.expectEqual(false, parsed.value.shutdown);
    try std.testing.expectEqualStrings("ts", parsed.value.language.?);
    try std.testing.expectEqualStrings("/tmp/foo.ts", parsed.value.filename.?);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", parsed.value.source.?);
}

test "protocol: request round-trips with null optionals" {
    const gpa = std.testing.allocator;

    const req: protocol.Request = .{ .binary_mtime = 0 };

    const bytes = try test_frame.frame(gpa, req);
    defer gpa.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try protocol.decode(protocol.Request, gpa, &reader);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 0), parsed.value.binary_mtime);
    try std.testing.expectEqual(false, parsed.value.shutdown);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.language);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.filename);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.source);
}

test "protocol: response round-trips with a populated report" {
    const gpa = std.testing.allocator;

    const diagnostics = [_]diagnostic.Diagnostic{.{
        .rule_id = "no-as-any",
        .language = "ts",
        .message = "as any is not allowed",
        .range = .{
            .start = .{ .line = 0, .column = 11 },
            .end = .{ .line = 0, .column = 24 },
        },
    }};

    const resp: protocol.Response = .{
        .status = .ok,
        .binary_mtime = 42,
        .report = .{
            .language = "ts",
            .diagnostics = &diagnostics,
            .clean = false,
        },
    };

    const bytes = try test_frame.frame(gpa, resp);
    defer gpa.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try protocol.decode(protocol.Response, gpa, &reader);
    defer parsed.deinit();

    try std.testing.expectEqual(protocol.Status.ok, parsed.value.status);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.binary_mtime);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.message);

    const report = parsed.value.report.?;
    try std.testing.expectEqualStrings("ts", report.language);
    try std.testing.expect(!report.clean);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);

    const d = report.diagnostics[0];
    try std.testing.expectEqualStrings("no-as-any", d.rule_id);
    try std.testing.expectEqualStrings("ts", d.language);
    try std.testing.expectEqualStrings("as any is not allowed", d.message);
    try std.testing.expectEqual(@as(u32, 0), d.range.start.line);
    try std.testing.expectEqual(@as(u32, 11), d.range.start.column);
    try std.testing.expectEqual(@as(u32, 0), d.range.end.line);
    try std.testing.expectEqual(@as(u32, 24), d.range.end.column);
}

test "protocol: readFrame returns the exact body" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("Content-Length: 5\r\n\r\nhello");
    const body = try protocol.readFrame(&reader, gpa, protocol.max_frame_bytes);
    defer gpa.free(body);

    try std.testing.expectEqualStrings("hello", body);
}

test "protocol: readFrame rejects a missing Content-Length" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("\r\n\r\nhello");
    try std.testing.expectError(error.MissingContentLength, protocol.readFrame(&reader, gpa, protocol.max_frame_bytes));
}

test "protocol: readFrame rejects a non-numeric Content-Length" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("Content-Length: abc\r\n\r\nhello");
    try std.testing.expectError(error.InvalidContentLength, protocol.readFrame(&reader, gpa, protocol.max_frame_bytes));
}

test "protocol: readFrame rejects a frame larger than the limit" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("Content-Length: 1000\r\n\r\n");
    try std.testing.expectError(error.FrameTooLarge, protocol.readFrame(&reader, gpa, 16));
}

test "protocol: readFrame rejects a truncated body" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("Content-Length: 100\r\n\r\nshort");
    try std.testing.expectError(error.EndOfStream, protocol.readFrame(&reader, gpa, protocol.max_frame_bytes));
}

test "protocol: decode rejects an invalid JSON body" {
    const gpa = std.testing.allocator;

    var reader: std.Io.Reader = .fixed("Content-Length: 9\r\n\r\n{not json");
    try std.testing.expectError(error.SyntaxError, protocol.decode(protocol.Request, gpa, &reader));
}

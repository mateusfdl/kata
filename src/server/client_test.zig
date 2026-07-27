const std = @import("std");

const client = @import("client.zig");
const protocol = @import("protocol.zig");
const test_fixture = @import("../test_fixture.zig");
const test_frame = @import("../test_frame.zig");

const request_body = "{\"shutdown\":false,\"language\":\"ts\",\"filename\":\"a.ts\",\"source\":\"const x = 1;\"}";

test "client: exchange sends the request frame and decodes the reply" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const reply = try test_frame.frame(gpa, protocol.Response{
        .status = .ok,
        .report = .{ .language = "ts", .diagnostics = &.{}, .clean = true },
    });
    defer gpa.free(reply);

    var reader: std.Io.Reader = .fixed(reply);
    var sent: std.Io.Writer.Allocating = .init(gpa);
    defer sent.deinit();

    const resp = try client.exchange(arena.allocator(), &reader, &sent.writer, .{
        .language = "ts",
        .filename = "a.ts",
        .source = "const x = 1;",
    });

    try std.testing.expectEqual(protocol.Status.ok, resp.status);
    try std.testing.expectEqualStrings("ts", resp.report.?.language);
    try std.testing.expect(resp.report.?.clean);
    try std.testing.expectEqual(@as(usize, 0), resp.report.?.diagnostics.len);
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ request_body.len, request_body }),
        sent.written(),
    );
}

test "client: exchange fails on a truncated reply" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var reader: std.Io.Reader = .fixed("Content-Length: 99\r\n\r\n{}");
    var sent: std.Io.Writer.Allocating = .init(gpa);
    defer sent.deinit();

    if (client.exchange(arena.allocator(), &reader, &sent.writer, .{
        .language = "ts",
        .source = "x",
    })) |_| return error.TestExpectedError else |_| {}
}

test "client: request returns null when no daemon listens" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const socket_path = try std.fmt.allocPrint(arena.allocator(), "{s}/absent.sock", .{dir});

    const resp = client.request(std.testing.io, arena.allocator(), socket_path, .{
        .language = "ts",
        .source = "const x = 1;",
    });

    try std.testing.expectEqual(@as(?protocol.Response, null), resp);
}

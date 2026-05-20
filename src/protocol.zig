const std = @import("std");

const diagnostic = @import("diagnostic.zig");

pub const max_frame_bytes: usize = 16 * 1024 * 1024;

const content_length_prefix = "Content-Length:";

pub const Status = enum { ok, stale, fail };

pub const Request = struct {
    binary_mtime: i64,
    shutdown: bool = false,
    language: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const Response = struct {
    status: Status,
    binary_mtime: i64,
    report: ?diagnostic.Report = null,
    message: ?[]const u8 = null,
};

pub const FrameError = error{
    MissingContentLength,
    InvalidContentLength,
    FrameTooLarge,
} || std.Io.Reader.DelimiterError || std.mem.Allocator.Error;

pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) std.Io.Writer.Error!void {
    try w.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try w.writeAll(payload);
    try w.flush();
}

pub fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator, max_bytes: usize) FrameError![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        const header = std.mem.trimEnd(u8, line, "\r\n");
        if (header.len == 0) break;
        if (!std.mem.startsWith(u8, header, content_length_prefix)) continue;
        const value = std.mem.trim(u8, header[content_length_prefix.len..], " ");
        content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
    }

    const len = content_length orelse return error.MissingContentLength;
    if (len > max_bytes) return error.FrameTooLarge;
    return r.readAlloc(gpa, len);
}

pub fn encode(gpa: std.mem.Allocator, w: *std.Io.Writer, value: anytype) !void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try std.json.Stringify.value(value, .{}, &buf.writer);
    try writeFrame(w, buf.written());
}

pub fn decode(comptime T: type, gpa: std.mem.Allocator, r: *std.Io.Reader) !std.json.Parsed(T) {
    const body = try readFrame(r, gpa, max_frame_bytes);
    defer gpa.free(body);
    return std.json.parseFromSlice(T, gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

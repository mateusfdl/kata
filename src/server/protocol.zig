const std = @import("std");

const diagnostic = @import("engine").diagnostic;
const language = @import("engine").language;
const linting = @import("linting.zig");

pub const max_frame_bytes: usize = 16 * 1024 * 1024;

const content_length_prefix = "Content-Length:";

pub const Status = enum { ok, fail };

pub const Request = struct {
    shutdown: bool = false,
    language: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    source: ?[]const u8 = null,

    pub fn fromInput(input: linting.Input) Request {
        return .{ .language = input.language.toString(), .filename = input.filename, .source = input.source };
    }

    pub fn lintInput(self: Request) error{ UnexpectedShutdown, MissingLanguage, UnsupportedLanguage, MissingSource }!linting.Input {
        if (self.shutdown) return error.UnexpectedShutdown;
        const resolved = switch (language.resolve(self.language orelse "", self.filename orelse "")) {
            .ok => |name| name,
            .missing => return error.MissingLanguage,
            .unsupported_language, .unknown_extension => return error.UnsupportedLanguage,
        };
        return .{ .language = resolved, .source = self.source orelse return error.MissingSource, .filename = self.filename };
    }
};

pub const Response = struct {
    status: Status,
    report: ?diagnostic.Report = null,
    message: ?[]const u8 = null,

    pub fn lintReport(self: Response) error{ InvalidLintResponse, RemoteLintFailed }!diagnostic.Report {
        switch (self.status) {
            .ok => {
                if (self.message != null) return error.InvalidLintResponse;
                return self.report orelse error.InvalidLintResponse;
            },
            .fail => {
                if (self.report != null or self.message == null) return error.InvalidLintResponse;
                return error.RemoteLintFailed;
            },
        }
    }
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

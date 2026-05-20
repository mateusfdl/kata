const std = @import("std");

const protocol = @import("protocol.zig");

pub fn frame(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try protocol.encode(gpa, &buf.writer, value);
    return buf.toOwnedSlice();
}

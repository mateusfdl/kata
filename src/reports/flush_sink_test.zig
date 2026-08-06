const std = @import("std");

pub const Sink = struct {
    interface: std.Io.Writer = .{ .vtable = &vtable, .buffer = &.{} },
    buffer: [4096]u8 = undefined,
    output: [4096]u8 = undefined,
    output_len: usize = 0,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    pub fn bind(self: *Sink) void {
        self.interface.buffer = &self.buffer;
    }

    pub fn written(self: *const Sink) []const u8 {
        return self.output[0..self.output_len];
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", writer));
        const buffered = writer.buffered();

        if (self.output_len + buffered.len > self.output.len) return error.WriteFailed;

        @memcpy(self.output[self.output_len..][0..buffered.len], buffered);
        self.output_len += buffered.len;
        writer.end = 0;

        return std.Io.Writer.countSplat(data, splat);
    }
};

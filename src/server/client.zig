const std = @import("std");

const protocol = @import("protocol.zig");

const buffer_size: usize = 4096;

pub fn exchange(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    req: protocol.Request,
) !protocol.Response {
    try protocol.encode(arena, writer, req);

    const parsed = try protocol.decode(protocol.Response, arena, reader);

    return parsed.value;
}

pub fn request(
    io: std.Io,
    arena: std.mem.Allocator,
    socket_path: []const u8,
    req: protocol.Request,
) ?protocol.Response {
    const address = std.Io.net.UnixAddress.init(socket_path) catch return null;
    const stream = address.connect(io) catch return null;
    defer stream.close(io);

    var read_buf: [buffer_size]u8 = undefined;
    var write_buf: [buffer_size]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    const resp = exchange(arena, &reader.interface, &writer.interface, req) catch return null;
    if (resp.status != .ok) return null;

    return resp;
}

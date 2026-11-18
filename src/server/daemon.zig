const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const linting = @import("linting.zig");
const protocol = @import("protocol.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;

pub const Context = linting.Context;

const IndexVisit = struct {
    io: std.Io,
    project: *lint.Project,
};

pub fn buildIndex(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    state: *lint.Project,
) !usize {
    const visit: IndexVisit = .{ .io = io, .project = state };

    return fs.source.walkFiles(io, gpa, root, visit, visitForIndex);
}

fn visitForIndex(visit: IndexVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    if (try fs.rules.isFixturePath(visit.io, path)) return;

    try visit.project.replace(source, lang, path);
}

pub fn binaryMtime(io: std.Io) !i64 {
    return fs.file.executableMtime(io);
}

pub fn sweepStaleSockets(io: std.Io, gpa: std.mem.Allocator, socket_path: []const u8) void {
    const dir_path = std.fs.path.dirname(socket_path) orelse return;
    const current = std.fs.path.basename(socket_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const stale = collectStaleSocketNames(io, arena.allocator(), dir_path, current) catch return;

    for (stale) |name| {
        var path_buf: [fs.socket.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        if (shutdownLiveSocket(arena.allocator(), path)) continue;

        deleteStaleSocket(io, dir_path, name);
    }
}

fn collectStaleSocketNames(
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    current: []const u8,
) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!isStaleSocketName(entry.name, current)) continue;

        try out.append(arena, try arena.dupe(u8, entry.name));
    }

    return out.toOwnedSlice(arena);
}

fn isStaleSocketName(name: []const u8, current: []const u8) bool {
    if (std.mem.eql(u8, name, current)) return false;
    if (std.mem.eql(u8, name, "kata.sock")) return true;

    return std.mem.startsWith(u8, name, "kata-") and std.mem.endsWith(u8, name, ".sock");
}

const legacy_shutdown_body = "{\"binary_mtime\":0,\"shutdown\":true}";

fn shutdownLiveSocket(gpa: std.mem.Allocator, path: []const u8) bool {
    const linux = std.os.linux;

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path.len], path);

    const socket_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(socket_rc);
    defer _ = linux.close(fd);

    const connect_rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    if (linux.errno(connect_rc) != .SUCCESS) return false;

    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    protocol.writeFrame(&frame.writer, legacy_shutdown_body) catch return true;
    _ = linux.write(fd, frame.written().ptr, frame.written().len);

    return true;
}

fn deleteStaleSocket(io: std.Io, dir_path: []const u8, name: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, name) catch {};
}

pub fn serve(
    gpa: std.mem.Allocator,
    ctx: Context,
    socket_path: []const u8,
) !void {
    const io = ctx.io;
    sweepStaleSockets(io, gpa, socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try bind(io, address, socket_path);
    defer server.deinit(io);
    defer fs.socket.deleteAbsolute(io, socket_path);
    fs.socket.installTeardown(socket_path);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => return err,
        };
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);

        if (processConnection(gpa, ctx, &reader.interface, &writer.interface)) break;
    }
}

fn bind(
    io: std.Io,
    address: std.Io.net.UnixAddress,
    socket_path: []const u8,
) !std.Io.net.Server {
    return address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => {
            if (address.connect(io)) |live| {
                live.close(io);
                return error.AlreadyRunning;
            } else |_| {}

            fs.socket.deleteAbsolute(io, socket_path);

            return address.listen(io, .{});
        },
        else => err,
    };
}

pub fn processConnection(
    gpa: std.mem.Allocator,
    ctx: Context,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = protocol.decode(protocol.Request, a, reader) catch {
        sendBestEffort(a, writer, reply(.fail, null, "malformed request"));
        return false;
    };

    if (parsed.value.shutdown) {
        sendBestEffort(a, writer, reply(.ok, null, "shutting down"));

        return true;
    }

    sendBestEffort(a, writer, handle(ctx, a, parsed.value));

    return false;
}

fn sendBestEffort(a: std.mem.Allocator, writer: *std.Io.Writer, resp: protocol.Response) void {
    protocol.encode(a, writer, resp) catch {};
}

/// The wire adapter validates optional request fields before entering the lint pipeline.
pub fn handle(ctx: Context, arena: std.mem.Allocator, req: protocol.Request) protocol.Response {
    const input = req.lintInput() catch |err| return reply(.fail, null, switch (err) {
        error.MissingLanguage => "missing language or filename",
        error.UnsupportedLanguage => "unsupported language",
        error.MissingSource => "missing source",
        error.UnexpectedShutdown => "unexpected shutdown request",
    });
    const report = linting.run(ctx, arena, input) catch |err|
        return reply(.fail, null, linting.failureMessage(err));
    return reply(.ok, report, null);
}

fn reply(
    status: protocol.Status,
    report: ?diagnostic.Report,
    message: ?[]const u8,
) protocol.Response {
    return .{
        .status = status,
        .report = report,
        .message = message,
    };
}

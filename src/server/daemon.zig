const std = @import("std");

const fs = @import("../fs.zig");
const lint = @import("engine");
const sources = @import("../sources.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;
const Engine = lint.Engine;

pub const Context = struct {
    engine: *Engine,
    io: std.Io,
    project: ?*lint.Project = null,
    ratchet: bool = false,
    cache: ?*sources.context.Cache = null,
    replay: ?*replay.ReplayCache = null,
    max_matches: u32 = 25,
    cache_dir: ?[]const u8 = null,
    cache_enabled: bool = false,
    rules_hash: [32]u8 = @splat(0),
};

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

pub fn handle(
    ctx: Context,
    arena: std.mem.Allocator,
    req: protocol.Request,
) protocol.Response {
    const lang = switch (language.resolve(req.language orelse "", req.filename orelse "")) {
        .ok => |n| n,
        .missing => return reply(.fail, null, "missing language or filename"),
        .unknown_extension, .unsupported_language => return reply(.fail, null, "unsupported language"),
    };

    const source = req.source orelse
        return reply(.fail, null, "missing source");

    if (req.filename) |filename| {
        const is_fixture = fs.rules.isFixturePath(ctx.io, filename) catch
            return reply(.fail, null, "fixture check failed");
        if (is_fixture)
            return reply(.ok, .{
                .language = lang.toString(),
                .diagnostics = &.{},
                .clean = true,
            }, null);
    }

    var engine = ctx.engine;
    var ratchet = ctx.ratchet;
    var replay_cache = ctx.replay;
    var max_matches = ctx.max_matches;
    var cache_enabled = ctx.cache_enabled;
    var rules_hash = ctx.rules_hash;

    if (ctx.cache) |cache| {
        const per_project = cache.acquire(arena, req.filename) catch
            return reply(.fail, null, "project context failed");

        if (per_project) |p| {
            engine = &p.engine;
            ratchet = p.resolved.ratchet;
            replay_cache = &p.replay;
            max_matches = p.resolved.max_matches_per_file;
            cache_enabled = p.resolved.cache;
            rules_hash = p.rules_hash;
        }
    }

    const disk_cache: ?fs.result_cache.Handle = handle: {
        if (!cache_enabled) break :handle null;
        if (ctx.project != null) break :handle null;
        const dir = ctx.cache_dir orelse break :handle null;

        break :handle .{ .dir = dir, .rules_hash = rules_hash };
    };

    if (ctx.project) |project| {
        project.configure(engine) catch return reply(.fail, null, "project configuration failed");
    }

    const replay_generation: u64 = if (ctx.project) |p|
        (if (p.hasCrossFileRules()) p.indexGeneration() else 0)
    else
        0;

    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &content_hash, .{});

    const diagnostics = replayed: {
        if (replay_cache) |rc| {
            if (req.filename) |path| {
                // A generation-matched hit proves the index has not changed
                // since the entry was stored, so the file's facts are already
                // indexed for this exact content and re-indexing is redundant.
                if (rc.get(path, lang, content_hash, replay_generation)) |cached| {
                    break :replayed arena.dupe(diagnostic.Diagnostic, cached) catch
                        return reply(.fail, null, "lint failed");
                }
            }
        }

        if (disk_cache) |cache| {
            if (req.filename) |path| {
                if (cache.isClean(ctx.io, content_hash, path))
                    break :replayed arena.alloc(diagnostic.Diagnostic, 0) catch
                        return reply(.fail, null, "lint failed");
            }
        }

        const fresh = if (ctx.project) |project| lint: {
            const path = req.filename orelse break :lint engine.lint(arena, source, lang, null) catch
                return reply(.fail, null, "lint failed");
            break :lint project.lint(arena, source, lang, path) catch
                return reply(.fail, null, "lint failed");
        } else engine.lint(arena, source, lang, req.filename) catch
            return reply(.fail, null, "lint failed");

        lint.fingerprint.assign(arena, req.filename orelse "", source, fresh) catch
            return reply(.fail, null, "fingerprint failed");

        if (replay_cache) |rc| {
            // Replay is an optimization. Allocation failure must not turn a
            // successful lint into a failed request.
            const post_lint_generation: u64 = if (ctx.project) |p|
                (if (p.hasCrossFileRules()) p.indexGeneration() else 0)
            else
                0;
            if (req.filename) |path| rc.put(path, lang, content_hash, post_lint_generation, fresh) catch {};
        }

        if (disk_cache) |cache| {
            if (req.filename) |path| {
                if (fresh.len == 0) cache.markClean(ctx.io, content_hash, path);
            }
        }

        break :replayed fresh;
    };

    applyRatchet(ctx, engine, ratchet, arena, lang, req.filename, source, diagnostics) catch
        return reply(.fail, null, "ratchet baseline failed");

    const all = appendProjectDiagnostics(ctx, arena, req.filename, diagnostics) catch
        return reply(.fail, null, "project analysis failed");

    lint.fingerprint.assign(arena, req.filename orelse "", source, all) catch
        return reply(.fail, null, "fingerprint failed");

    const rendered = lint.caps.apply(arena, all, engine.settings, max_matches) catch
        return reply(.fail, null, "caps failed");

    return reply(.ok, .{
        .language = lang.toString(),
        .diagnostics = rendered,
        .clean = !diagnostic.hasErrors(all),
    }, null);
}

fn applyRatchet(
    ctx: Context,
    engine: *Engine,
    ratchet: bool,
    arena: std.mem.Allocator,
    lang: language.Name,
    filename: ?[]const u8,
    source: []const u8,
    diagnostics: []diagnostic.Diagnostic,
) !void {
    if (!ratchet) return;

    const io = ctx.io;
    const path = filename orelse return;

    if (!diagnostic.hasErrors(diagnostics)) return;

    const baseline_source = fs.source.read(io, arena, path) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return,
        else => return err,
    };

    const before = try engine.lint(arena, baseline_source, lang, path);
    try lint.fingerprint.assign(arena, path, baseline_source, before);
    _ = try lint.baseline.demote(arena, source, diagnostics, baseline_source, before);
}

fn appendProjectDiagnostics(
    ctx: Context,
    arena: std.mem.Allocator,
    filename: ?[]const u8,
    diagnostics: []diagnostic.Diagnostic,
) ![]diagnostic.Diagnostic {
    const project = ctx.project orelse return diagnostics;
    const path = filename orelse return diagnostics;

    const violations = try project.diagnostics(arena, path);
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    try out.appendSlice(arena, diagnostics);

    for (violations) |v| try out.append(arena, v.diagnostic);

    std.mem.sort(diagnostic.Diagnostic, out.items, {}, diagnostic.lessThan);

    return out.toOwnedSlice(arena);
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

const std = @import("std");

const lint = @import("../lint.zig");
const protocol = @import("protocol.zig");
const walk = @import("../sources.zig").walk;

const diagnostic = lint.diagnostic;
const language = lint.language;
const project_rule = lint.project_rule;
const Engine = lint.Engine;

pub const Context = struct {
    engine: *Engine,
    binary_mtime: i64,
    io: std.Io,
    project: ?*ProjectState = null,
    ratchet: bool = false,
};

pub const ProjectState = struct {
    rules: []const project_rule.ProjectRule,
    index: lint.ProjectIndex,

    pub fn init(gpa: std.mem.Allocator, rules: []const project_rule.ProjectRule) ProjectState {
        return .{ .rules = rules, .index = lint.ProjectIndex.init(gpa) };
    }

    pub fn deinit(self: *ProjectState) void {
        self.index.deinit();
    }
};

const IndexVisit = struct {
    engine: *Engine,
    index: *lint.ProjectIndex,
};

pub fn buildIndex(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    root: []const u8,
    state: *ProjectState,
) !usize {
    const visit: IndexVisit = .{ .engine = engine, .index = &state.index };
    return walk.walkSourceFiles(io, gpa, root, visit, visitForIndex);
}

fn visitForIndex(visit: IndexVisit, lang: language.Name, source: []const u8, path: []const u8) anyerror!void {
    try visit.index.put(try visit.engine.extractFacts(visit.index.allocator, source, lang, path));
}

pub fn binaryMtime(io: std.Io) !i64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    const stat = try std.Io.Dir.cwd().statFile(io, buf[0..n], .{});
    return stat.mtime.toMilliseconds();
}

var teardown_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var teardown_path_len: usize = 0;

fn handleTeardownSignal(_: std.posix.SIG) callconv(.c) void {
    _ = std.os.linux.unlink(teardown_path_buf[0..teardown_path_len :0]);
    std.os.linux.exit_group(0);
}

fn installTeardown(socket_path: []const u8) void {
    if (socket_path.len >= teardown_path_buf.len) return;
    @memcpy(teardown_path_buf[0..socket_path.len], socket_path);
    teardown_path_buf[socket_path.len] = 0;
    teardown_path_len = socket_path.len;

    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleTeardownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

pub fn serve(
    gpa: std.mem.Allocator,
    ctx: Context,
    socket_path: []const u8,
) !void {
    const io = ctx.io;
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try bind(io, address, socket_path);
    defer server.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    installTeardown(socket_path);

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
            std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
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
        sendBestEffort(a, writer, reply(ctx, .fail, null, "malformed request"));
        return false;
    };

    if (parsed.value.shutdown) {
        sendBestEffort(a, writer, reply(ctx, .ok, null, "shutting down"));
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
    if (req.binary_mtime != 0 and req.binary_mtime != ctx.binary_mtime)
        return reply(ctx, .stale, null, "daemon is running a stale binary");

    const lang = switch (language.resolve(req.language orelse "", req.filename orelse "")) {
        .ok => |n| n,
        .missing => return reply(ctx, .fail, null, "missing language or filename"),
        .unknown_extension, .unsupported_language => return reply(ctx, .fail, null, "unsupported language"),
    };

    const source = req.source orelse
        return reply(ctx, .fail, null, "missing source");

    const diagnostics = ctx.engine.lint(arena, source, lang, req.filename) catch
        return reply(ctx, .fail, null, "lint failed");

    applyRatchet(ctx, arena, lang, req.filename, diagnostics) catch
        return reply(ctx, .fail, null, "ratchet baseline failed");

    const all = appendProjectDiagnostics(ctx, arena, source, lang, req.filename, diagnostics) catch
        return reply(ctx, .fail, null, "project analysis failed");

    return reply(ctx, .ok, .{
        .language = lang.toString(),
        .diagnostics = all,
        .clean = !diagnostic.hasErrors(all),
    }, null);
}

fn applyRatchet(
    ctx: Context,
    arena: std.mem.Allocator,
    lang: language.Name,
    filename: ?[]const u8,
    diagnostics: []diagnostic.Diagnostic,
) !void {
    if (!ctx.ratchet) return;
    const io = ctx.io;
    const path = filename orelse return;
    if (!diagnostic.hasErrors(diagnostics)) return;

    const baseline_source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(walk.max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return,
        else => return err,
    };
    const baseline = try ctx.engine.lint(arena, baseline_source, lang, path);

    var demote: std.ArrayList(usize) = .empty;
    for (diagnostics, 0..) |d, i| {
        if (d.severity != .@"error") continue;
        const before = countErrors(baseline, d.rule_id);
        const now = countErrors(diagnostics, d.rule_id);
        if (now <= before) try demote.append(arena, i);
    }
    for (demote.items) |i| diagnostics[i].severity = .warn;
}

fn countErrors(diagnostics: []const diagnostic.Diagnostic, rule_id: []const u8) usize {
    var n: usize = 0;
    for (diagnostics) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.rule_id, rule_id)) n += 1;
    }
    return n;
}

fn appendProjectDiagnostics(
    ctx: Context,
    arena: std.mem.Allocator,
    source: []const u8,
    lang: language.Name,
    filename: ?[]const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const diagnostic.Diagnostic {
    const project = ctx.project orelse return diagnostics;
    const path = filename orelse return diagnostics;

    try project.index.put(try ctx.engine.extractFacts(project.index.allocator, source, lang, path));

    const violations = try project_rule.evaluate(arena, project.rules, ctx.engine.warnings, &project.index);
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    try out.appendSlice(arena, diagnostics);
    for (violations) |v| {
        if (std.mem.eql(u8, v.path, path)) try out.append(arena, v.diagnostic);
    }
    return out.toOwnedSlice(arena);
}

fn reply(
    ctx: Context,
    status: protocol.Status,
    report: ?diagnostic.Report,
    message: ?[]const u8,
) protocol.Response {
    return .{
        .status = status,
        .binary_mtime = ctx.binary_mtime,
        .report = report,
        .message = message,
    };
}

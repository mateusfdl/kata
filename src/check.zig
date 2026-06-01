const std = @import("std");

const engine_mod = @import("engine.zig");
const language = @import("language.zig");

const max_file_bytes: usize = 4 * 1024 * 1024;
const max_gitignore_bytes: usize = 1024 * 1024;
const git_dir = ".git";
const gitignore_file = ".gitignore";

pub const Outcome = enum { clean, violations };

const Counts = struct { files: usize, violations: usize };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Outcome {
    const stat = try std.Io.Dir.cwd().statFile(io, target, .{});
    const counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, stdout),
        .file => try checkFile(io, gpa, engine, target, stdout),
        else => return error.UnsupportedTarget,
    };

    try stdout.print("checked {d} files, {d} violations\n", .{ counts.files, counts.violations });
    try stdout.flush();
    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Counts {
    const lang = languageOf(target) orelse return error.UnsupportedTarget;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(max_file_bytes));
    defer gpa.free(source);

    return .{ .files = 1, .violations = try reportFile(gpa, engine, lang, source, target, stdout) };
}

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Counts {
    var dir = try std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    defer dir.close(io);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const ignored = try collectIgnoredDirs(io, scratch.allocator(), &dir);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    const base = std.mem.trimEnd(u8, target, "/");
    var counts: Counts = .{ .files = 0, .violations = 0 };
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!containsName(ignored, entry.basename)) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const lang = languageOf(entry.basename) orelse continue;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(source);

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, entry.path });
        defer gpa.free(path);

        counts.files += 1;
        counts.violations += try reportFile(gpa, engine, lang, source, path, stdout);
    }
    return counts;
}

fn collectIgnoredDirs(io: std.Io, arena: std.mem.Allocator, dir: *std.Io.Dir) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, git_dir);
    if (dir.readFileAlloc(io, gitignore_file, arena, .limited(max_gitignore_bytes))) |bytes| {
        try appendIgnoredDirs(arena, bytes, &list);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    return list.toOwnedSlice(arena);
}

pub fn appendIgnoredDirs(
    arena: std.mem.Allocator,
    gitignore: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, gitignore, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
        if (std.mem.indexOfAny(u8, line, "*?[") != null) continue;
        const name = std.mem.trimEnd(u8, std.mem.trimStart(u8, line, "/"), "/");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) continue;
        try out.append(arena, name);
    }
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn languageOf(name: []const u8) ?language.Name {
    return switch (language.resolve("", name)) {
        .ok => |n| n,
        else => null,
    };
}

fn reportFile(
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    stdout: *std.Io.Writer,
) !usize {
    const diagnostics = try engine.lint(gpa, source, lang, path);
    defer gpa.free(diagnostics);

    for (diagnostics) |d| {
        try stdout.print("{s}:{d}:{d} [{s}] {s}\n", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.rule_id,
            d.message,
        });
    }
    return diagnostics.len;
}

const std = @import("std");

const lint = @import("../lint.zig");
const file = @import("file.zig");
const paths = @import("path");

const language = lint.language;

pub const max_file_bytes: usize = 4 * 1024 * 1024;

const max_gitignore_bytes: usize = 1024 * 1024;
const git_dir = ".git";
const gitignore_file = ".gitignore";

pub fn walkFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    target: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), language.Name, []const u8, []const u8) anyerror!void,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    defer dir.close(io);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const ignored = try collectIgnoredDirs(io, scratch.allocator(), &dir);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!containsName(ignored, entry.basename)) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const lang = languageOf(entry.basename) orelse continue;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(source);

        const indexed_path = try indexPath(gpa, target, entry.path);
        defer gpa.free(indexed_path);

        files += 1;
        try visit(context, lang, source, indexed_path);
    }
    return files;
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    return file.readAlloc(io, allocator, file_path, max_file_bytes);
}

pub fn statTarget(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return file.stat(io, path);
}

pub fn readOptional(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    return file.readOptionalAlloc(io, allocator, file_path, max_file_bytes);
}

pub fn indexPath(gpa: std.mem.Allocator, target: []const u8, sub_path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, target, "/");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) return gpa.dupe(u8, sub_path);
    const base = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[2..] else trimmed;
    return paths.join(gpa, base, sub_path);
}

pub fn languageOf(name: []const u8) ?language.Name {
    return switch (language.resolve("", name)) {
        .ok => |n| n,
        else => null,
    };
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

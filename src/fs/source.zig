const std = @import("std");

const lint = @import("engine");
const file = @import("file.zig");
const gitignore = @import("gitignore.zig");
const paths = @import("path");

const language = lint.language;

pub const max_file_bytes: usize = 4 * 1024 * 1024;

const max_gitignore_bytes: usize = 1024 * 1024;
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
    const arena = scratch.allocator();

    var stack = try gitignore.Stack.init(arena);
    if (dir.readFileAlloc(io, gitignore_file, arena, .limited(max_gitignore_bytes))) |bytes| {
        try stack.pushScope("", bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},

        else => return err,
    }

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        stack.popTo(entry.path);
        if (entry.kind == .directory) {
            switch (stack.decide(entry.path, true)) {
                .ignored => {
                    if (stack.negationCouldMatchUnder(entry.path)) {
                        try stack.pushExcluded(entry.path);
                        try walker.enter(io, entry);
                    }
                },
                .included, .unmatched => {
                    try pushChildScope(io, &stack, arena, entry);
                    try walker.enter(io, entry);
                },
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (stack.decide(entry.path, false) == .ignored) continue;
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

fn pushChildScope(
    io: std.Io,
    stack: *gitignore.Stack,
    arena: std.mem.Allocator,
    entry: std.Io.Dir.Walker.Entry,
) !void {
    const sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.basename, gitignore_file });
    if (entry.dir.readFileAlloc(io, sub_path, arena, .limited(max_gitignore_bytes))) |bytes| {
        try stack.pushScope(entry.path, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},

        else => return err,
    }
}

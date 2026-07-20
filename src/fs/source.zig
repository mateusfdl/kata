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
    const prefix = try loadAncestorScopes(io, &stack, arena, target);
    if (dir.readFileAlloc(io, gitignore_file, arena, .limited(max_gitignore_bytes))) |bytes| {
        try stack.pushScope(prefix, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},

        else => return err,
    }

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var full_path: std.ArrayList(u8) = .empty;
    if (prefix.len > 0) {
        try full_path.appendSlice(arena, prefix);
        try full_path.append(arena, '/');
    }
    const prefix_len = full_path.items.len;

    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        full_path.shrinkRetainingCapacity(prefix_len);
        try full_path.appendSlice(arena, entry.path);
        const full = full_path.items;

        stack.popTo(full);
        if (entry.kind == .directory) {
            switch (stack.decide(full, true)) {
                .ignored => {
                    if (stack.negationCouldMatchUnder(full)) {
                        try stack.pushExcluded(full);
                        try walker.enter(io, entry);
                    }
                },
                .included, .unmatched => {
                    try pushChildScope(io, &stack, arena, entry, full);
                    try walker.enter(io, entry);
                },
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (stack.decide(full, false) == .ignored) continue;
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

pub fn write(io: std.Io, file_path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = contents });
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
    full: []const u8,
) !void {
    const sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.basename, gitignore_file });
    if (entry.dir.readFileAlloc(io, sub_path, arena, .limited(max_gitignore_bytes))) |bytes| {
        try stack.pushScope(full, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},

        else => return err,
    }
}

fn loadAncestorScopes(
    io: std.Io,
    stack: *gitignore.Stack,
    arena: std.mem.Allocator,
    target: []const u8,
) ![]const u8 {
    const abs = if (std.fs.path.isAbsolute(target))
        try std.fs.path.resolve(arena, &.{target})
    else blk: {
        const cwd = std.process.currentPathAlloc(io, arena) catch return "";
        break :blk try std.fs.path.resolve(arena, &.{ cwd, target });
    };

    var root: []const u8 = abs;
    while (true) {
        const marker = try paths.join(arena, root, ".git");
        if (file.stat(io, marker)) |_| break else |_| {}
        root = std.fs.path.dirname(root) orelse return "";
    }
    if (root.len == abs.len) return "";
    const prefix = abs[root.len + 1 ..];

    try pushAncestorScope(io, stack, arena, root, "");
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, prefix, idx, '/')) |slash| {
        try pushAncestorScope(io, stack, arena, root, prefix[0..slash]);
        idx = slash + 1;
    }

    return prefix;
}

fn pushAncestorScope(
    io: std.Io,
    stack: *gitignore.Stack,
    arena: std.mem.Allocator,
    root: []const u8,
    rel: []const u8,
) !void {
    const dir_path = if (rel.len == 0) root else try paths.join(arena, root, rel);
    const gitignore_path = try paths.join(arena, dir_path, gitignore_file);
    const bytes = try file.readOptionalAlloc(io, arena, gitignore_path, max_gitignore_bytes) orelse return;
    try stack.pushScope(rel, bytes);
}

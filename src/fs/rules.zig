const std = @import("std");

const lint = @import("../lint.zig");
const paths = @import("path.zig");
const source_files = @import("source.zig");

const language = lint.language;

pub const kata_suffix = ".kata";

pub const project_dir_name = "project";

pub const RuleFile = struct {
    langs: []const language.Name,
    id: []const u8,
    body: []const u8,
    source: lint.Source,
    project: bool = false,
};

pub const FixtureFile = struct {
    lang: language.Name,
    source: []const u8,
    path: []const u8,
};

pub fn createNew(io: std.Io, lang_dir: []const u8, file_path: []const u8, body: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, lang_dir);
    var out = try std.Io.Dir.cwd().createFile(io, file_path, .{ .exclusive = true });
    defer out.close(io);
    try out.writeStreamingAll(io, body);
}

pub fn collectProjectFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) ![]const RuleFile {
    var root = try openRoot(io, dir_path);
    defer root.close(io);
    return collectRuleFiles(allocator, io, &root, .project);
}

pub fn collectUserFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) ![]const RuleFile {
    var root = openRoot(io, dir_path) catch |err| switch (err) {
        error.RulesDirMissing => return &.{},
        else => return err,
    };
    defer root.close(io);
    return collectRuleFiles(allocator, io, &root, .user);
}

pub fn collectFixtureFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    rules_dir: []const u8,
) ![]const FixtureFile {
    var root = try openRoot(io, rules_dir);
    defer root.close(io);

    var files: std.ArrayList(FixtureFile) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try collectLanguageFixtureFiles(io, arena, &root, rules_dir, entry.name, &files);
    }
    return files.toOwnedSlice(arena);
}

fn collectRuleFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *std.Io.Dir,
    source: lint.Source,
) ![]const RuleFile {
    var files: std.ArrayList(RuleFile) = .empty;
    var root_iter = root.iterate();
    while (try root_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, project_dir_name)) {
            try collectProjectRuleFiles(allocator, io, root, source, &files);
            continue;
        }
        try collectLanguageRuleFiles(allocator, io, root, entry.name, source, &files);
    }
    return files.toOwnedSlice(allocator);
}

fn openRoot(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    return cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => error.RulesDirMissing,
        error.NotDir => error.RulesDirNotADirectory,
        else => err,
    };
}

fn collectLanguageRuleFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *std.Io.Dir,
    lang_subdir: []const u8,
    source: lint.Source,
    out: *std.ArrayList(RuleFile),
) !void {
    var langs_buf: [language.max_langs_per_dir]language.Name = undefined;
    const parsed_langs = try language.parseDirName(lang_subdir, &langs_buf);
    const langs = try allocator.dupe(language.Name, parsed_langs);

    var lang_dir = try root.openDir(io, lang_subdir, .{ .iterate = true });
    defer lang_dir.close(io);

    var file_iter = lang_dir.iterate();
    while (try file_iter.next(io)) |fentry| {
        if (fentry.kind != .file) continue;
        const id = ruleId(fentry.name) orelse continue;
        if (id.len == 0) return error.InvalidRule;
        try out.append(allocator, .{
            .langs = langs,
            .id = try allocator.dupe(u8, id),
            .body = try lang_dir.readFileAlloc(io, fentry.name, allocator, .limited(std.math.maxInt(usize))),
            .source = source,
        });
    }
}

fn collectProjectRuleFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *std.Io.Dir,
    source: lint.Source,
    out: *std.ArrayList(RuleFile),
) !void {
    var project_dir = try root.openDir(io, project_dir_name, .{ .iterate = true });
    defer project_dir.close(io);

    var file_iter = project_dir.iterate();
    while (try file_iter.next(io)) |fentry| {
        if (fentry.kind != .file) continue;
        const id = ruleId(fentry.name) orelse continue;
        if (id.len == 0) return error.InvalidRule;
        try out.append(allocator, .{
            .langs = &.{},
            .id = try allocator.dupe(u8, id),
            .body = try project_dir.readFileAlloc(io, fentry.name, allocator, .limited(std.math.maxInt(usize))),
            .source = source,
            .project = true,
        });
    }
}

pub fn ruleId(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, kata_suffix)) return null;
    return name[0 .. name.len - kata_suffix.len];
}

fn collectLanguageFixtureFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: *std.Io.Dir,
    rules_dir: []const u8,
    lang_subdir: []const u8,
    out: *std.ArrayList(FixtureFile),
) !void {
    var lang_dir = try root.openDir(io, lang_subdir, .{});
    defer lang_dir.close(io);

    var tests_dir = lang_dir.openDir(io, "tests", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer tests_dir.close(io);

    var it = tests_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const lang = source_files.languageOf(entry.name) orelse continue;
        const dir_path = try paths.join(arena, rules_dir, lang_subdir);
        const tests_path = try paths.join(arena, dir_path, "tests");
        try out.append(arena, .{
            .lang = lang,
            .source = try tests_dir.readFileAlloc(io, entry.name, arena, .limited(source_files.max_file_bytes)),
            .path = try paths.join(arena, tests_path, entry.name),
        });
    }
}

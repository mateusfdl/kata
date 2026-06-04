const std = @import("std");

const embedded_rules = @import("embedded_rules");
const lint = @import("../lint.zig");

const language = lint.language;
const rule = lint.rule;

pub const RuleSet = lint.RuleSet;
pub const Source = lint.Source;
pub const Warning = lint.Warning;

const scm_suffix = ".scm";

pub const Sources = struct {
    external_dir: ?[]const u8 = null,
    user_dir: ?[]const u8 = null,
    skip_embedded: bool = false,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    sources: Sources,
) !RuleSet {
    var set: RuleSet = .{ .allocator = allocator };
    errdefer set.deinit();

    if (!sources.skip_embedded) try addEmbedded(&set);
    if (sources.external_dir) |dir_path| try addExternal(allocator, io, &set, dir_path);
    if (sources.user_dir) |dir_path| try addUserDir(allocator, io, &set, dir_path);

    return set;
}

fn addEmbedded(set: *RuleSet) !void {
    inline for (std.enums.values(language.Name)) |lang| {
        const field_name = "embedded_" ++ @tagName(lang);
        if (@hasDecl(embedded_rules, field_name)) {
            for (@field(embedded_rules, field_name)) |entry| {
                try set.upsert(lang, .{ .id = entry.id, .language = lang, .source = entry.source }, .embedded);
            }
        }
    }
}

fn addExternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    dir_path: []const u8,
) !void {
    var root = try openRulesRoot(io, dir_path);
    defer root.close(io);
    try walkLanguages(allocator, io, set, &root, .external);
}

fn addUserDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    dir_path: []const u8,
) !void {
    var root = openRulesRoot(io, dir_path) catch |err| switch (err) {
        error.RulesDirMissing => return,
        else => return err,
    };
    defer root.close(io);
    try walkLanguages(allocator, io, set, &root, .user);
}

fn walkLanguages(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    root: *std.Io.Dir,
    source: Source,
) !void {
    var root_iter = root.iterate();
    while (try root_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try loadLanguageDir(allocator, io, set, root, entry.name, source);
    }
}

fn openRulesRoot(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    return cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => error.RulesDirMissing,
        error.NotDir => error.RulesDirNotADirectory,
        else => err,
    };
}

fn loadLanguageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    root: *std.Io.Dir,
    lang_subdir: []const u8,
    source: Source,
) !void {
    var langs_buf: [language.max_langs_per_dir]language.Name = undefined;
    const langs = try language.parseDirName(lang_subdir, &langs_buf);

    var lang_dir = try root.openDir(io, lang_subdir, .{ .iterate = true });
    defer lang_dir.close(io);

    var file_iter = lang_dir.iterate();
    while (try file_iter.next(io)) |fentry| {
        if (fentry.kind != .file) continue;
        if (!std.mem.endsWith(u8, fentry.name, scm_suffix)) continue;
        try loadRuleFile(allocator, io, set, langs, &lang_dir, fentry.name, source);
    }
}

fn loadRuleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    langs: []const language.Name,
    lang_dir: *std.Io.Dir,
    file_name: []const u8,
    source: Source,
) !void {
    const id_raw = stripScmSuffix(file_name);
    if (id_raw.len == 0) return error.InvalidRule;

    const id = try allocator.dupe(u8, id_raw);
    const body = try lang_dir.readFileAlloc(io, file_name, allocator, .limited(std.math.maxInt(usize)));

    for (langs) |lang_name| {
        try set.upsert(lang_name, .{
            .id = id,
            .language = lang_name,
            .source = body,
        }, source);
    }
}

fn stripScmSuffix(name: []const u8) []const u8 {
    return name[0 .. name.len - scm_suffix.len];
}

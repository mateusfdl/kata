const std = @import("std");

const embedded_rules = @import("embedded_rules");
const language = @import("language.zig");
const rule = @import("rule.zig");

const scm_suffix = ".scm";

pub const Sources = struct {
    external_dir: ?[]const u8 = null,
    skip_embedded: bool = false,
};

pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    by_lang: std.EnumArray(language.Name, std.ArrayList(rule.RawRule)) = .initFill(.empty),

    pub fn deinit(self: *RuleSet) void {
        var it = self.by_lang.iterator();
        while (it.next()) |entry| {
            entry.value.deinit(self.allocator);
        }
    }

    pub fn get(self: *const RuleSet, name: language.Name) []const rule.RawRule {
        return self.by_lang.getPtrConst(name).items;
    }

    pub fn append(self: *RuleSet, name: language.Name, r: rule.RawRule) !void {
        try self.by_lang.getPtr(name).append(self.allocator, r);
    }
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

    return set;
}

fn addEmbedded(set: *RuleSet) !void {
    if (@hasDecl(embedded_rules, "embedded_ts")) {
        for (embedded_rules.embedded_ts) |entry| {
            try set.append(.ts, .{ .id = entry.id, .language = .ts, .source = entry.source });
        }
    }
    if (@hasDecl(embedded_rules, "embedded_tsx")) {
        for (embedded_rules.embedded_tsx) |entry| {
            try set.append(.tsx, .{ .id = entry.id, .language = .tsx, .source = entry.source });
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

    var root_iter = root.iterate();
    while (try root_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try loadLanguageDir(allocator, io, set, &root, entry.name);
    }
}

fn openRulesRoot(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    return cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => error.ExternalRulesMissing,
        error.NotDir => error.ExternalRulesNotADirectory,
        else => err,
    };
}

fn loadLanguageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    root: *std.Io.Dir,
    lang_subdir: []const u8,
) !void {
    const lang_name = language.Name.fromString(lang_subdir) orelse return error.InvalidRule;

    var lang_dir = try root.openDir(io, lang_subdir, .{ .iterate = true });
    defer lang_dir.close(io);

    var file_iter = lang_dir.iterate();
    while (try file_iter.next(io)) |fentry| {
        if (fentry.kind != .file) continue;
        if (!std.mem.endsWith(u8, fentry.name, scm_suffix)) continue;
        try loadRuleFile(allocator, io, set, lang_name, &lang_dir, fentry.name);
    }
}

fn loadRuleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    set: *RuleSet,
    lang_name: language.Name,
    lang_dir: *std.Io.Dir,
    file_name: []const u8,
) !void {
    const id_raw = stripScmSuffix(file_name);
    if (id_raw.len == 0) return error.InvalidRule;

    const data = try lang_dir.readFileAlloc(io, file_name, allocator, .limited(std.math.maxInt(usize)));
    const id = try allocator.dupe(u8, id_raw);

    try set.append(lang_name, .{
        .id = id,
        .language = lang_name,
        .source = data,
    });
}

fn stripScmSuffix(name: []const u8) []const u8 {
    return name[0 .. name.len - scm_suffix.len];
}

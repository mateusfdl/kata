const std = @import("std");

const language = @import("language.zig");
const loader = @import("loader.zig");
const rule = @import("rule.zig");

pub const max_config_bytes: usize = 64 * 1024;

pub const ScopedId = struct {
    lang: language.Name,
    id: []const u8,
};

pub const Config = struct {
    disabled_scoped: []const ScopedId,
    disabled_bare: []const []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const ParseError = error{
    UnknownTopLevelKey,
    TabInIndent,
    BadIndent,
    MalformedListItem,
    ContentAfterKey,
    UnknownLanguage,
    InvalidRuleId,
    UnexpectedListItem,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    line: u32 = 0,
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTopLevelKey => "unknown top-level key (expected 'disabled')",
        error.TabInIndent => "tabs are not allowed in indentation",
        error.BadIndent => "indent must be 0 or 2 spaces",
        error.MalformedListItem => "list item must be '  - <rule-id>'",
        error.ContentAfterKey => "no inline content allowed after key",
        error.UnknownLanguage => "unknown language (expected ts, tsx, or go)",
        error.InvalidRuleId => "rule id must match [A-Za-z0-9_-]+",
        error.UnexpectedListItem => "list item without a preceding key",
        else => @errorName(err),
    };
}

const State = enum { top, in_disabled };

pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: *Diagnostic) ParseError!Config {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = .init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var scoped: std.ArrayList(ScopedId) = .empty;
    var bare: std.ArrayList([]const u8) = .empty;

    var line_no: u32 = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    var state: State = .top;

    while (iter.next()) |raw_line| {
        line_no += 1;
        diag.line = line_no;

        const without_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const without_comment = stripComment(without_cr);

        if (containsTab(without_comment)) return error.TabInIndent;

        const trimmed_right = std.mem.trimEnd(u8, without_comment, " ");
        if (trimmed_right.len == 0) continue;

        const indent = leadingSpaces(trimmed_right);
        const content = trimmed_right[indent..];

        if (indent == 0) {
            state = try parseTopLevelKey(content);
            continue;
        }

        if (indent == 2) {
            if (state != .in_disabled) return error.UnexpectedListItem;
            try appendListItem(arena, &scoped, &bare, content);
            continue;
        }

        return error.BadIndent;
    }

    diag.line = 0;
    return .{
        .disabled_scoped = try scoped.toOwnedSlice(arena),
        .disabled_bare = try bare.toOwnedSlice(arena),
        .arena = arena_ptr,
    };
}

fn parseTopLevelKey(content: []const u8) ParseError!State {
    if (std.mem.endsWith(u8, content, ":")) {
        const key = content[0 .. content.len - 1];
        if (std.mem.eql(u8, key, "disabled")) return .in_disabled;
        return error.UnknownTopLevelKey;
    }
    if (std.mem.indexOfScalar(u8, content, ':') != null) return error.ContentAfterKey;
    return error.UnknownTopLevelKey;
}

fn appendListItem(
    arena: std.mem.Allocator,
    scoped: *std.ArrayList(ScopedId),
    bare: *std.ArrayList([]const u8),
    content: []const u8,
) ParseError!void {
    if (!std.mem.startsWith(u8, content, "- ")) return error.MalformedListItem;
    const item = std.mem.trimStart(u8, content[2..], " ");
    if (item.len == 0) return error.MalformedListItem;

    if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
        const lang_str = item[0..slash];
        const id = item[slash + 1 ..];
        if (!rule.isValidId(lang_str) or !rule.isValidId(id)) return error.InvalidRuleId;
        const lang = language.Name.fromString(lang_str) orelse return error.UnknownLanguage;
        try scoped.append(arena, .{
            .lang = lang,
            .id = try arena.dupe(u8, id),
        });
        return;
    }

    if (!rule.isValidId(item)) return error.InvalidRuleId;
    try bare.append(arena, try arena.dupe(u8, item));
}

fn stripComment(line: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, line, '#')) |idx| line[0..idx] else line;
}

fn containsTab(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\t') != null;
}

fn leadingSpaces(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

pub fn loadFromDisk(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    diag: *Diagnostic,
) !?Config {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        const path = try std.fmt.allocPrint(gpa, "{s}/kata/rules.yaml", .{xdg});
        defer gpa.free(path);
        if (try tryReadFile(gpa, io, path)) |source| {
            defer gpa.free(source);
            return try parse(gpa, source, diag);
        }
    }
    if (environ.get("HOME")) |home| {
        const path = try std.fmt.allocPrint(gpa, "{s}/.config/kata/rules.yaml", .{home});
        defer gpa.free(path);
        if (try tryReadFile(gpa, io, path)) |source| {
            defer gpa.free(source);
            return try parse(gpa, source, diag);
        }
    }
    return null;
}

fn tryReadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn filterDisabled(set: *loader.RuleSet, cfg: Config) void {
    for (std.enums.values(language.Name)) |lang| {
        const list = set.by_lang.getPtr(lang);
        var i: usize = 0;
        while (i < list.items.len) {
            if (isDisabled(lang, list.items[i].id, cfg)) {
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn isDisabled(lang: language.Name, id: []const u8, cfg: Config) bool {
    for (cfg.disabled_bare) |bare| {
        if (std.mem.eql(u8, bare, id)) return true;
    }
    for (cfg.disabled_scoped) |s| {
        if (s.lang == lang and std.mem.eql(u8, s.id, id)) return true;
    }
    return false;
}

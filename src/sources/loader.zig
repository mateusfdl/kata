const std = @import("std");

const embedded_rules = @import("embedded_rules");
const fs = @import("../fs.zig");
const lint = @import("../lint.zig");

const language = lint.language;

pub const RuleSet = lint.RuleSet;
pub const Source = lint.Source;
pub const Warning = lint.Warning;

const max_id_bytes = 128;

pub const Diagnostic = struct {
    lang: ?language.Name = null,
    source: Source = .embedded,
    id_len: usize = 0,
    id_buf: [max_id_bytes]u8 = undefined,

    pub fn id(self: *const Diagnostic) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const Sources = struct {
    user_dir: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
    skip_embedded: bool = false,
    diag: ?*Diagnostic = null,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    sources: Sources,
) !RuleSet {
    var set: RuleSet = .{ .allocator = allocator };
    errdefer set.deinit();

    if (!sources.skip_embedded) try addEmbedded(&set);
    if (sources.user_dir) |dir_path| try addRuleFiles(&set, sources.diag, try fs.rules.collectUserFiles(allocator, io, dir_path));
    if (sources.project_dir) |dir_path| try addRuleFiles(&set, sources.diag, try fs.rules.collectProjectFiles(allocator, io, dir_path));

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

fn addRuleFiles(set: *RuleSet, diag: ?*Diagnostic, files: []const fs.rules.RuleFile) !void {
    for (files) |file| {
        const id = try set.allocator.dupe(u8, file.id);
        for (file.langs) |lang_name| {
            set.upsert(lang_name, .{
                .id = id,
                .language = lang_name,
                .source = file.body,
                .format = file.format,
            }, file.source) catch |err| {
                if (err == error.DuplicateRuleFormats) fillDiag(diag, set.duplicate.?);
                return err;
            };
        }
    }
}

fn fillDiag(diag: ?*Diagnostic, dup: Warning) void {
    const d = diag orelse return;
    d.lang = dup.lang;
    d.source = dup.source;
    d.id_len = @min(dup.id.len, d.id_buf.len);
    @memcpy(d.id_buf[0..d.id_len], dup.id[0..d.id_len]);
}

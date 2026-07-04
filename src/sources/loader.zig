const std = @import("std");

const embedded_rules = @import("embedded_rules");
const fs = @import("../fs.zig");
const lint = @import("../lint.zig");

const language = lint.language;

pub const RuleSet = lint.RuleSet;
pub const Source = lint.Source;
pub const Warning = lint.Warning;

pub const Sources = struct {
    user_dir: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
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
    if (sources.user_dir) |dir_path| try addRuleFiles(&set, try fs.rules.collectUserFiles(allocator, io, dir_path));
    if (sources.project_dir) |dir_path| try addRuleFiles(&set, try fs.rules.collectProjectFiles(allocator, io, dir_path));

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

fn addRuleFiles(set: *RuleSet, files: []const fs.rules.RuleFile) !void {
    for (files) |file| {
        const id = try set.allocator.dupe(u8, file.id);
        for (file.langs) |lang_name| {
            try set.upsert(lang_name, .{
                .id = id,
                .language = lang_name,
                .source = file.body,
            }, file.source);
        }
    }
}

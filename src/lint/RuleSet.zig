const std = @import("std");

const language = @import("../core.zig").language;
const rule = @import("../core.zig").rule;

pub const Source = rule.Source;

pub const Warning = struct {
    source: Source,
    lang: ?language.Name,
    id: []const u8,
};

pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    by_lang: std.EnumArray(language.Name, std.ArrayList(rule.RawRule)) = .initFill(.empty),
    project: std.ArrayList(rule.RawRule) = .empty,
    warnings: std.ArrayList(Warning) = .empty,

    pub fn deinit(self: *RuleSet) void {
        var it = self.by_lang.iterator();

        while (it.next()) |entry| {
            entry.value.deinit(self.allocator);
        }

        self.project.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    pub fn get(self: *const RuleSet, name: language.Name) []const rule.RawRule {
        return self.by_lang.getPtrConst(name).items;
    }

    pub fn projectRaws(self: *const RuleSet) []const rule.RawRule {
        return self.project.items;
    }

    pub fn upsertProject(self: *RuleSet, r: rule.RawRule, source: Source) !void {
        var entry = r;
        entry.origin = source;

        for (self.project.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing.id, entry.id)) {
                if (existing.origin == source) {
                    try self.warnings.append(self.allocator, .{
                        .source = source,
                        .lang = null,
                        .id = entry.id,
                    });
                }
                self.project.items[idx] = entry;

                return;
            }
        }
        try self.project.append(self.allocator, entry);
    }

    pub fn append(self: *RuleSet, name: language.Name, r: rule.RawRule) !void {
        try self.by_lang.getPtr(name).append(self.allocator, r);
    }

    pub fn upsert(self: *RuleSet, name: language.Name, r: rule.RawRule, source: Source) !void {
        var entry = r;
        entry.origin = source;
        const list = self.by_lang.getPtr(name);

        for (list.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing.id, entry.id)) {
                if (existing.origin == source) {
                    try self.warnings.append(self.allocator, .{
                        .source = source,
                        .lang = name,
                        .id = entry.id,
                    });
                }
                list.items[idx] = entry;

                return;
            }
        }
        try list.append(self.allocator, entry);
    }
};

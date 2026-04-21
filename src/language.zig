const std = @import("std");
const ts = @import("tree_sitter");

extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;

pub const Name = enum {
    ts,
    tsx,

    pub fn toString(self: Name) []const u8 {
        return infos.get(self).canonical;
    }

    pub fn fromString(s: []const u8) ?Name {
        for (std.enums.values(Name)) |n| {
            if (std.mem.eql(u8, s, infos.get(n).canonical)) return n;
        }
        return null;
    }

    pub fn fromExtension(ext_lower: []const u8) ?Name {
        for (std.enums.values(Name)) |n| {
            if (std.mem.eql(u8, ext_lower, infos.get(n).extension)) return n;
        }
        return null;
    }
};

const Info = struct {
    canonical: []const u8,
    extension: []const u8,
};

const infos: std.EnumArray(Name, Info) = .init(.{
    .ts = .{ .canonical = "ts", .extension = ".ts" },
    .tsx = .{ .canonical = "tsx", .extension = ".tsx" },
});

pub const Registry = struct {
    cache: std.EnumArray(Name, ?*const ts.Language) = .initFill(null),

    pub fn init() Registry {
        return .{};
    }

    pub fn deinit(self: *Registry) void {
        self.cache = .initFill(null);
    }

    pub fn get(self: *Registry, name: Name) *const ts.Language {
        if (self.cache.get(name)) |cached| return cached;
        const lang: *const ts.Language = switch (name) {
            .ts => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
        };
        self.cache.set(name, lang);
        return lang;
    }
};

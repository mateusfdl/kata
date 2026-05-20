const std = @import("std");
const ts = @import("tree_sitter");

extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;

pub const Name = enum {
    ts,
    tsx,
    go,

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
    .go = .{ .canonical = "go", .extension = ".go" },
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
            .go => tree_sitter_go(),
        };
        self.cache.set(name, lang);
        return lang;
    }
};

pub const Resolution = union(enum) {
    ok: Name,
    missing,
    unknown_extension: []const u8,
    unsupported_language: []const u8,
};

pub fn resolve(lang_flag: []const u8, filename: []const u8) Resolution {
    if (lang_flag.len > 0) {
        if (Name.fromString(lang_flag)) |n| return .{ .ok = n };
        return .{ .unsupported_language = lang_flag };
    }
    if (filename.len == 0) return .missing;
    return resolveFromFilename(filename);
}

fn resolveFromFilename(filename: []const u8) Resolution {
    const ext = extOf(filename);
    if (ext.len == 0) return .{ .unknown_extension = ext };

    var buf: [8]u8 = undefined;
    if (ext.len > buf.len) return .{ .unknown_extension = ext };
    for (ext, 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    const ext_lower = buf[0..ext.len];

    if (Name.fromExtension(ext_lower)) |n| return .{ .ok = n };
    return .{ .unknown_extension = ext };
}

fn extOf(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') return "";
        if (c == '.') return path[i - 1 ..];
    }
    return "";
}

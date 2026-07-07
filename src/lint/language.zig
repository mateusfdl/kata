const std = @import("std");
const path = @import("../fs/path.zig");
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

pub const max_langs_per_dir: usize = std.enums.values(Name).len;

pub const supported_list = blk: {
    var text: []const u8 = "";
    const names = std.enums.values(Name);

    for (names, 0..) |n, i| {
        if (i > 0) text = text ++ (if (i == names.len - 1) ", or " else ", ");
        text = text ++ infos.get(n).canonical;
    }

    break :blk text;
};

pub fn parseDirName(name: []const u8, out: []Name) ![]Name {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '+');

    while (it.next()) |token| {
        if (n >= out.len) return error.InvalidRule;
        out[n] = Name.fromString(token) orelse return error.InvalidRule;
        n += 1;
    }

    return out[0..n];
}

const Info = struct {
    canonical: []const u8,
    extension: []const u8,
};

const infos: std.EnumArray(Name, Info) = .init(.{
    .ts = .{ .canonical = "ts", .extension = ".ts" },
    .tsx = .{ .canonical = "tsx", .extension = ".tsx" },
    .go = .{ .canonical = "go", .extension = ".go" },
});

pub fn grammar(name: Name) *const ts.Language {
    return switch (name) {
        .ts => tree_sitter_typescript(),
        .tsx => tree_sitter_tsx(),
        .go => tree_sitter_go(),
    };
}

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
    const ext = path.fileExtension(filename);
    if (ext.len == 0) return .{ .unknown_extension = ext };

    var buf: [8]u8 = undefined;
    if (ext.len > buf.len) return .{ .unknown_extension = ext };
    for (ext, 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    const ext_lower = buf[0..ext.len];

    if (Name.fromExtension(ext_lower)) |n| return .{ .ok = n };

    return .{ .unknown_extension = ext };
}

const std = @import("std");
const language = @import("engine").language;

const Sha256 = std.crypto.hash.sha2.Sha256;

const Key = [Sha256.digest_length * 2]u8;

pub const Handle = struct {
    dir: []const u8,
    rules_hash: [32]u8,

    pub fn entry(self: Handle, input: struct { language: language.Name, source: []const u8, path: []const u8 }) Entry {
        var content_hash: [32]u8 = undefined;
        Sha256.hash(input.source, &content_hash, .{});
        return .{ .dir = self.dir, .key = key(self.rules_hash, input.language, content_hash, input.path) };
    }
};

pub const Entry = struct {
    dir: []const u8,
    key: Key,

    pub fn isClean(self: Entry, io: std.Io) bool {
        return hasEntry(io, self.dir, self.key);
    }

    pub fn markClean(self: Entry, io: std.Io) void {
        writeEntry(io, self.dir, self.key);
    }
};

pub fn dir(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !?[]const u8 {
    if (environ.get("XDG_CACHE_HOME")) |xdg|
        return try std.fmt.allocPrint(arena, "{s}/kata/clean", .{xdg});
    if (environ.get("HOME")) |home|
        return try std.fmt.allocPrint(arena, "{s}/.cache/kata/clean", .{home});

    return null;
}

fn key(rules_hash: [32]u8, lang: language.Name, content_hash: [32]u8, path: []const u8) Key {
    var hasher = Sha256.init(.{});
    hasher.update("kata-clean-v2\x00");
    hasher.update(&rules_hash);
    hasher.update(lang.toString());
    hasher.update("\x00");
    hasher.update(&content_hash);
    hasher.update(&std.mem.toBytes(@as(u32, @intCast(path.len))));
    hasher.update(path);

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var out: Key = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;

    return out;
}

fn hasEntry(io: std.Io, dir_path: []const u8, entry: Key) bool {
    var cache = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer cache.close(io);

    _ = cache.statFile(io, &entry, .{}) catch return false;

    return true;
}

fn writeEntry(io: std.Io, dir_path: []const u8, entry: Key) void {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    var cache = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer cache.close(io);

    cache.writeFile(io, .{ .sub_path = &entry, .data = "" }) catch {};
}

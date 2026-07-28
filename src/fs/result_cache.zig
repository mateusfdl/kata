const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Key = [Sha256.digest_length * 2]u8;

pub const Handle = struct {
    dir: []const u8,
    rules_hash: [32]u8,

    pub fn isClean(self: Handle, io: std.Io, content_hash: [32]u8, path: []const u8) bool {
        return hasEntry(io, self.dir, key(self.rules_hash, content_hash, path));
    }

    pub fn markClean(self: Handle, io: std.Io, content_hash: [32]u8, path: []const u8) void {
        writeEntry(io, self.dir, key(self.rules_hash, content_hash, path));
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

pub fn key(rules_hash: [32]u8, content_hash: [32]u8, path: []const u8) Key {
    var hasher = Sha256.init(.{});
    hasher.update(&rules_hash);
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

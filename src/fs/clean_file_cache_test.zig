const std = @import("std");

const clean_file_cache = @import("clean_file_cache.zig");
const test_fixture = @import("../test_fixture.zig");

const rules_a: [32]u8 = @splat(1);
const rules_b: [32]u8 = @splat(2);
const content_a = "const a = 3;";
const content_b = "const b = 4;";

fn handle(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, buf: []u8, rules_hash: [32]u8) !clean_file_cache.Handle {
    const dir = try test_fixture.relativeTmpPath(buf, &tmp.sub_path);

    return .{
        .dir = try std.fmt.allocPrint(arena, "{s}/cache", .{dir}),
        .rules_hash = rules_hash,
    };
}

test "clean_file_cache: an unwritten entry is not clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    try std.testing.expectEqual(false, h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).isClean(io));
}

test "clean_file_cache: a marked entry reads back clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).markClean(io);

    try std.testing.expectEqual(true, h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).isClean(io));
}

test "clean_file_cache: marking twice stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).markClean(io);
    h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).markClean(io);

    try std.testing.expectEqual(true, h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).isClean(io));
}

test "clean_file_cache: language, content, rules, and path each change the entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).markClean(io);

    try std.testing.expectEqual(false, h.entry(.{ .language = .ts, .source = content_b, .path = "src/a.ts" }).isClean(io));
    try std.testing.expectEqual(false, h.entry(.{ .language = .ts, .source = content_a, .path = "src/b.ts" }).isClean(io));

    try std.testing.expectEqual(false, h.entry(.{ .language = .tsx, .source = content_a, .path = "src/a.ts" }).isClean(io));

    var other_buf: [256]u8 = undefined;
    var other = try handle(arena.allocator(), &tmp, &other_buf, rules_b);
    try std.testing.expectEqual(false, other.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).isClean(io));
}

test "clean_file_cache: an uncreatable directory degrades to a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocker", .data = "not a directory" });

    var buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&buf, &tmp.sub_path);
    const h: clean_file_cache.Handle = .{
        .dir = try std.fmt.allocPrint(arena.allocator(), "{s}/blocker/clean", .{dir}),
        .rules_hash = rules_a,
    };

    h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).markClean(io);

    try std.testing.expectEqual(false, h.entry(.{ .language = .ts, .source = content_a, .path = "src/a.ts" }).isClean(io));
}

test "clean_file_cache: dir prefers XDG_CACHE_HOME over HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var with_xdg: std.process.Environ.Map = .init(a);
    try with_xdg.put("XDG_CACHE_HOME", "/x/cache");
    try with_xdg.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/x/cache/kata/clean", (try clean_file_cache.dir(a, &with_xdg)).?);

    var home_only: std.process.Environ.Map = .init(a);
    try home_only.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/home/u/.cache/kata/clean", (try clean_file_cache.dir(a, &home_only)).?);

    var empty: std.process.Environ.Map = .init(a);
    try std.testing.expectEqual(@as(?[]const u8, null), try clean_file_cache.dir(a, &empty));
}

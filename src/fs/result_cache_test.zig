const std = @import("std");

const result_cache = @import("result_cache.zig");
const test_fixture = @import("../test_fixture.zig");

const rules_a: [32]u8 = @splat(1);
const rules_b: [32]u8 = @splat(2);
const content_a: [32]u8 = @splat(3);
const content_b: [32]u8 = @splat(4);

fn handle(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, buf: []u8, rules_hash: [32]u8) !result_cache.Handle {
    const dir = try test_fixture.relativeTmpPath(buf, &tmp.sub_path);

    return .{
        .dir = try std.fmt.allocPrint(arena, "{s}/cache", .{dir}),
        .rules_hash = rules_hash,
    };
}

test "result_cache: an unwritten entry is not clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    try std.testing.expectEqual(false, h.isClean(io, content_a, "src/a.ts"));
}

test "result_cache: a marked entry reads back clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.markClean(io, content_a, "src/a.ts");

    try std.testing.expectEqual(true, h.isClean(io, content_a, "src/a.ts"));
}

test "result_cache: marking twice stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.markClean(io, content_a, "src/a.ts");
    h.markClean(io, content_a, "src/a.ts");

    try std.testing.expectEqual(true, h.isClean(io, content_a, "src/a.ts"));
}

test "result_cache: content, rules, and path each change the entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const h = try handle(arena.allocator(), &tmp, &buf, rules_a);

    h.markClean(io, content_a, "src/a.ts");

    try std.testing.expectEqual(false, h.isClean(io, content_b, "src/a.ts"));
    try std.testing.expectEqual(false, h.isClean(io, content_a, "src/b.ts"));

    var other_buf: [256]u8 = undefined;
    var other = try handle(arena.allocator(), &tmp, &other_buf, rules_b);
    try std.testing.expectEqual(false, other.isClean(io, content_a, "src/a.ts"));
}

test "result_cache: an uncreatable directory degrades to a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocker", .data = "not a directory" });

    var buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&buf, &tmp.sub_path);
    const h: result_cache.Handle = .{
        .dir = try std.fmt.allocPrint(arena.allocator(), "{s}/blocker/clean", .{dir}),
        .rules_hash = rules_a,
    };

    h.markClean(io, content_a, "src/a.ts");

    try std.testing.expectEqual(false, h.isClean(io, content_a, "src/a.ts"));
}

test "result_cache: dir prefers XDG_CACHE_HOME over HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var with_xdg: std.process.Environ.Map = .init(a);
    try with_xdg.put("XDG_CACHE_HOME", "/x/cache");
    try with_xdg.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/x/cache/kata/clean", (try result_cache.dir(a, &with_xdg)).?);

    var home_only: std.process.Environ.Map = .init(a);
    try home_only.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/home/u/.cache/kata/clean", (try result_cache.dir(a, &home_only)).?);

    var empty: std.process.Environ.Map = .init(a);
    try std.testing.expectEqual(@as(?[]const u8, null), try result_cache.dir(a, &empty));
}

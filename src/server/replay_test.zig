const std = @import("std");

const replay = @import("replay.zig");

const diagnostic = @import("engine").diagnostic;

const hash_a: [32]u8 = @splat(1);
const hash_b: [32]u8 = @splat(2);

fn sample(arena: std.mem.Allocator, message: []const u8) ![]diagnostic.Diagnostic {
    const context = try arena.alloc(diagnostic.Context, 1);
    context[0] = .{
        .kind = .method,
        .name = try arena.dupe(u8, "render"),
        .range = .{ .start = .{ .line = 0, .column = 0 }, .end = .{ .line = 3, .column = 1 } },
    };

    const suggestions = try arena.alloc(diagnostic.Suggestion, 1);
    suggestions[0] = .{
        .label = try arena.dupe(u8, "use unknown"),
        .range = .{ .start = .{ .line = 1, .column = 4 }, .end = .{ .line = 1, .column = 7 } },
        .replacement = try arena.dupe(u8, "unknown"),
    };

    const out = try arena.alloc(diagnostic.Diagnostic, 1);
    out[0] = .{
        .rule_id = try arena.dupe(u8, "no-as-any"),
        .language = try arena.dupe(u8, "ts"),
        .message = try arena.dupe(u8, message),
        .range = .{ .start = .{ .line = 1, .column = 4 }, .end = .{ .line = 1, .column = 7 } },
        .fingerprint = try arena.dupe(u8, "abc123"),
        .context = context,
        .fix = .{
            .range = .{ .start = .{ .line = 1, .column = 4 }, .end = .{ .line = 1, .column = 7 } },
            .replacement = try arena.dupe(u8, "unknown"),
            .safety = .safe,
        },
        .suggestions = suggestions,
    };

    return out;
}

test "replay: empty cache misses" {
    var cache = try replay.ReplayCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_a));
    try std.testing.expectEqual(@as(usize, 0), cache.pooledEntries());
    try std.testing.expectEqual(@as(usize, 0), cache.availablePoolEntries());
}

test "replay: put then get returns the stored diagnostics" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try cache.put("src/a.ts", .ts, hash_a, try sample(arena.allocator(), "as any is not allowed"));

    const hit = cache.get("src/a.ts", .ts, hash_a).?;
    try std.testing.expectEqual(@as(usize, 1), hit.len);
    try std.testing.expectEqualStrings("no-as-any", hit[0].rule_id);
    try std.testing.expectEqualStrings("as any is not allowed", hit[0].message);
    try std.testing.expectEqualStrings("abc123", hit[0].fingerprint);
    try std.testing.expectEqualStrings("render", hit[0].context[0].name);
    try std.testing.expectEqualStrings("unknown", hit[0].fix.?.replacement);
    try std.testing.expectEqualStrings("use unknown", hit[0].suggestions[0].label);
}

test "replay: a different content hash misses and put replaces the entry" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try cache.put("src/a.ts", .ts, hash_a, try sample(arena.allocator(), "first"));

    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_b));

    try cache.put("src/a.ts", .ts, hash_b, try sample(arena.allocator(), "second"));
    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_a));
    try std.testing.expectEqualStrings("second", cache.get("src/a.ts", .ts, hash_b).?[0].message);
}

test "replay: stored diagnostics survive the source arena teardown" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try cache.put("src/a.ts", .ts, hash_a, try sample(arena.allocator(), "outlives"));
    }

    const hit = cache.get("src/a.ts", .ts, hash_a).?;
    try std.testing.expectEqualStrings("outlives", hit[0].message);
    try std.testing.expectEqualStrings("render", hit[0].context[0].name);
}

test "replay: stored diagnostics preserve capped state" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diagnostics = try sample(arena.allocator(), "capped");
    diagnostics[0].capped = true;
    try cache.put("src/a.ts", .ts, hash_a, diagnostics);

    try std.testing.expectEqual(true, cache.get("src/a.ts", .ts, hash_a).?[0].capped);
}

test "replay: LRU eviction keeps a promoted path" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 2);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try cache.put("src/a.ts", .ts, hash_a, try sample(arena.allocator(), "a"));
    try cache.put("src/b.ts", .ts, hash_a, try sample(arena.allocator(), "b"));

    _ = cache.get("src/a.ts", .ts, hash_a);
    try cache.put("src/c.ts", .ts, hash_a, try sample(arena.allocator(), "c"));

    try std.testing.expectEqualStrings("a", cache.get("src/a.ts", .ts, hash_a).?[0].message);
    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/b.ts", .ts, hash_a));
    try std.testing.expectEqualStrings("c", cache.get("src/c.ts", .ts, hash_a).?[0].message);
}

test "replay: an empty diagnostic slice is a valid cached value" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    try cache.put("src/clean.ts", .ts, hash_a, &.{});

    const hit = cache.get("src/clean.ts", .ts, hash_a).?;
    try std.testing.expectEqual(@as(usize, 0), hit.len);
}

test "replay: path lookup uses byte equality" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    const stored_path = try gpa.dupe(u8, "src/a.ts");
    defer gpa.free(stored_path);
    const lookup_path = try gpa.dupe(u8, "src/a.ts");
    defer gpa.free(lookup_path);
    try cache.put(stored_path, .ts, hash_a, &.{});

    try std.testing.expectEqual(@as(usize, 0), cache.get(lookup_path, .ts, hash_a).?.len);
}

test "replay: stale content does not promote an entry" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 2);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try cache.put("src/a.ts", .ts, hash_a, try sample(arena.allocator(), "a"));
    try cache.put("src/b.ts", .ts, hash_a, try sample(arena.allocator(), "b"));
    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_b));
    _ = cache.get("src/b.ts", .ts, hash_a);
    try cache.put("src/c.ts", .ts, hash_a, try sample(arena.allocator(), "c"));

    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_a));
    try std.testing.expectEqualStrings("b", cache.get("src/b.ts", .ts, hash_a).?[0].message);
}

test "replay: repeated eviction reuses bounded pool slots" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 2);
    defer cache.deinit();

    for (0..32) |index| {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "src/{d}.ts", .{index});
        try cache.put(path, .ts, hash_a, &.{});
    }

    try std.testing.expectEqual(@as(usize, 2), cache.pooledEntries());
    try std.testing.expectEqual(@as(usize, 1), cache.availablePoolEntries());
}

test "replay: init rejects zero capacity" {
    try std.testing.expectError(
        error.InvalidReplayCapacity,
        replay.ReplayCache.init(std.testing.allocator, 0),
    );
}

test "replay: failed replacement preserves the stored entry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var cache = try replay.ReplayCache.init(gpa, 2);
    defer cache.deinit();

    try cache.put("src/a.ts", .ts, hash_a, &.{});
    const in_use = cache.pooledEntries();
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, cache.put("src/a.ts", .ts, hash_b, &.{}));
    try std.testing.expectEqual(@as(usize, 0), cache.get("src/a.ts", .ts, hash_a).?.len);
    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/a.ts", .ts, hash_b));
    try std.testing.expectEqual(in_use, cache.pooledEntries());
}

test "replay: failed full insertion preserves LRU order" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var cache = try replay.ReplayCache.init(gpa, 2);
    defer cache.deinit();

    try cache.put("src/a.ts", .ts, hash_a, &.{});
    try cache.put("src/b.ts", .ts, hash_a, &.{});
    _ = cache.get("src/a.ts", .ts, hash_a);
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, cache.put("src/c.ts", .ts, hash_a, &.{}));
    try std.testing.expectEqual(@as(usize, 2), cache.pooledEntries());
    failing.fail_index = std.math.maxInt(usize);
    try cache.put("src/c.ts", .ts, hash_a, &.{});

    try std.testing.expectEqual(@as(usize, 0), cache.get("src/a.ts", .ts, hash_a).?.len);
    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/b.ts", .ts, hash_a));
    try std.testing.expectEqual(@as(usize, 0), cache.get("src/c.ts", .ts, hash_a).?.len);
}

test "replay: language is part of cache identity" {
    const gpa = std.testing.allocator;
    var cache = try replay.ReplayCache.init(gpa, 4);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try cache.put("src/input", .ts, hash_a, try sample(arena.allocator(), "typescript"));

    try std.testing.expectEqual(@as(?[]const diagnostic.Diagnostic, null), cache.get("src/input", .go, hash_a));
    try cache.put("src/input", .go, hash_a, try sample(arena.allocator(), "go"));

    try std.testing.expectEqualStrings("typescript", cache.get("src/input", .ts, hash_a).?[0].message);
    try std.testing.expectEqualStrings("go", cache.get("src/input", .go, hash_a).?[0].message);
}

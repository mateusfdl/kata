const std = @import("std");

const language = @import("language.zig");
const loader = @import("loader.zig");
const rule = @import("rule.zig");
const test_fixture = @import("test_fixture.zig");

test "upsert: first insertion appends without warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((x) @match)" }, .embedded);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("no-any", set.get(.ts)[0].id);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: collision replaces in place and emits one warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((builtin) @match)" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((user) @match)" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("((user) @match)", set.get(.ts)[0].source);

    try std.testing.expectEqual(@as(usize, 1), set.warnings.items.len);
    const w = set.warnings.items[0];
    try std.testing.expectEqual(loader.Source.user, w.source);
    try std.testing.expectEqual(language.Name.ts, w.lang);
    try std.testing.expectEqualStrings("no-any", w.id);
}

test "upsert: external overrides embedded, then user overrides external" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "1" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "2" }, .external);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "3" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("3", set.get(.ts)[0].source);
    try std.testing.expectEqual(@as(usize, 2), set.warnings.items.len);
    try std.testing.expectEqual(loader.Source.external, set.warnings.items[0].source);
    try std.testing.expectEqual(loader.Source.user, set.warnings.items[1].source);
}

test "upsert: different ids in same language coexist" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "a" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-console", .language = .ts, .source = "b" }, .embedded);

    try std.testing.expectEqual(@as(usize, 2), set.get(.ts).len);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

const relativeTmpPath = test_fixture.relativeTmpPath;

test "load: user_dir reads scm files into the right language slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "ts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ts/local-rule.scm",
        .data = "((identifier) @match)",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path_buf: [256]u8 = undefined;
    const rel = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var set = try loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .user_dir = rel,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("local-rule", set.get(.ts)[0].id);
    try std.testing.expectEqualStrings("((identifier) @match)", set.get(.ts)[0].source);
}

test "load: missing user_dir is silently empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var set = try loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .user_dir = ".zig-cache/tmp/does-not-exist-XYZ",
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), set.get(.ts).len);
    try std.testing.expectEqual(@as(usize, 0), set.get(.tsx).len);
    try std.testing.expectEqual(@as(usize, 0), set.get(.go).len);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "load: missing external_dir errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .external_dir = ".zig-cache/tmp/does-not-exist-XYZ",
    });
    try std.testing.expectError(error.RulesDirMissing, got);
}

test "load: user_dir overrides embedded with a recorded warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "ts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ts/no-console.scm",
        .data = "((my_override) @match)",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path_buf: [256]u8 = undefined;
    const rel = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var set = try loader.load(arena.allocator(), std.testing.io, .{ .user_dir = rel });
    defer set.deinit();

    var found_ts_no_console: usize = 0;
    var override_source: ?[]const u8 = null;
    for (set.get(.ts)) |r| {
        if (std.mem.eql(u8, r.id, "no-console")) {
            found_ts_no_console += 1;
            override_source = r.source;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found_ts_no_console);
    try std.testing.expectEqualStrings("((my_override) @match)", override_source.?);

    var saw_user_warning_for_no_console = false;
    for (set.warnings.items) |w| {
        if (w.source == .user and w.lang == .ts and std.mem.eql(u8, w.id, "no-console")) {
            saw_user_warning_for_no_console = true;
        }
    }
    try std.testing.expect(saw_user_warning_for_no_console);
}

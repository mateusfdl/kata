const std = @import("std");

const lint = @import("../lint.zig");
const loader = @import("loader.zig");
const test_fixture = @import("../test_fixture.zig");

const language = lint.language;
const rule = lint.rule;

test "upsert: first insertion appends without warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((x) @match)" }, .embedded);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("no-any", set.get(.ts)[0].id);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: same-tier collision replaces in place and emits one warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((first) @match)" }, .user);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((second) @match)" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("((second) @match)", set.get(.ts)[0].source);

    try std.testing.expectEqual(@as(usize, 1), set.warnings.items.len);
    const w = set.warnings.items[0];
    try std.testing.expectEqual(loader.Source.user, w.source);
    try std.testing.expectEqual(language.Name.ts, w.lang);
    try std.testing.expectEqualStrings("no-any", w.id);
}

test "upsert: same tier same id across formats errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((x) @match)" }, .user);
    const got = set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "rule no-any {}", .format = .kata }, .user);

    try std.testing.expectError(error.DuplicateRuleFormats, got);
    const dup = set.duplicate.?;
    try std.testing.expectEqual(loader.Source.user, dup.source);
    try std.testing.expectEqual(language.Name.ts, dup.lang);
    try std.testing.expectEqualStrings("no-any", dup.id);
}

test "upsert: cross-tier override across formats stays silent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "((x) @match)" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "rule no-any {}", .format = .kata }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqual(rule.Format.kata, set.get(.ts)[0].format);
    try std.testing.expectEqualStrings("rule no-any {}", set.get(.ts)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: user overrides embedded, then project overrides user, silently" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "1" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "2" }, .user);
    try set.upsert(.ts, .{ .id = "no-any", .language = .ts, .source = "3" }, .project);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("3", set.get(.ts)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
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
    try std.testing.expectEqual(rule.Format.scm, set.get(.ts)[0].format);
}

test "load: user_dir reads kata files with the kata format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "ts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ts/local-rule.kata",
        .data = "rule local-rule {}",
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
    try std.testing.expectEqualStrings("rule local-rule {}", set.get(.ts)[0].source);
    try std.testing.expectEqual(rule.Format.kata, set.get(.ts)[0].format);
}

test "load: same id in both formats in one dir errors with the scoped id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "ts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ts/no-x.scm",
        .data = "((identifier) @match)",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ts/no-x.kata",
        .data = "rule no-x {}",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path_buf: [256]u8 = undefined;
    const rel = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var diag: loader.Diagnostic = .{};
    const got = loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .user_dir = rel,
        .diag = &diag,
    });

    try std.testing.expectError(error.DuplicateRuleFormats, got);
    try std.testing.expectEqual(language.Name.ts, diag.lang.?);
    try std.testing.expectEqualStrings("no-x", diag.id());
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

test "load: missing project_dir errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .project_dir = ".zig-cache/tmp/does-not-exist-XYZ",
    });
    try std.testing.expectError(error.RulesDirMissing, got);
}

test "load: user_dir overrides embedded without a warning" {
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
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "load: project_dir overrides user_dir silently" {
    var user_tmp = std.testing.tmpDir(.{});
    defer user_tmp.cleanup();
    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();

    try user_tmp.dir.createDirPath(std.testing.io, "go");
    try user_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "go/no-panic.scm",
        .data = "((user_version) @match)",
    });
    try project_tmp.dir.createDirPath(std.testing.io, "go");
    try project_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "go/no-panic.scm",
        .data = "((project_version) @match)",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var user_buf: [256]u8 = undefined;
    var project_buf: [256]u8 = undefined;
    const user_rel = try relativeTmpPath(&user_buf, &user_tmp.sub_path);
    const project_rel = try relativeTmpPath(&project_buf, &project_tmp.sub_path);

    var set = try loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .user_dir = user_rel,
        .project_dir = project_rel,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), set.get(.go).len);
    try std.testing.expectEqualStrings("((project_version) @match)", set.get(.go)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

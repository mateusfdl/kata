const std = @import("std");

const lint = @import("../lint.zig");
const loader = @import("loader.zig");
const test_fixture = @import("../test_fixture.zig");

const language = lint.language;

test "upsert: first insertion appends without warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .source = "((x) @match)" }, .embedded);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("no-any", set.get(.ts)[0].id);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: same-tier collision replaces in place and emits one warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .source = "((first) @match)" }, .user);
    try set.upsert(.ts, .{ .id = "no-any", .source = "((second) @match)" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("((second) @match)", set.get(.ts)[0].source);

    try std.testing.expectEqual(@as(usize, 1), set.warnings.items.len);
    const w = set.warnings.items[0];
    try std.testing.expectEqual(loader.Source.user, w.source);
    try std.testing.expectEqual(language.Name.ts, w.lang);
    try std.testing.expectEqualStrings("no-any", w.id);
}

test "upsert: cross-tier override replaces and stays silent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .source = "rule no-any { a }" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .source = "rule no-any { b }" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("rule no-any { b }", set.get(.ts)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: user overrides embedded, then project overrides user, silently" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .source = "1" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-any", .source = "2" }, .user);
    try set.upsert(.ts, .{ .id = "no-any", .source = "3" }, .project);

    try std.testing.expectEqual(@as(usize, 1), set.get(.ts).len);
    try std.testing.expectEqualStrings("3", set.get(.ts)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsert: different ids in same language coexist" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsert(.ts, .{ .id = "no-any", .source = "a" }, .embedded);
    try set.upsert(.ts, .{ .id = "no-console", .source = "b" }, .embedded);

    try std.testing.expectEqual(@as(usize, 2), set.get(.ts).len);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

const relativeTmpPath = test_fixture.relativeTmpPath;

test "load: user_dir ignores non-kata files" {
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

    try std.testing.expectEqual(@as(usize, 0), set.get(.ts).len);
}

test "load: user_dir reads kata files into the right language slot" {
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
        .sub_path = "ts/no-console.kata",
        .data = "rule no-console { override }",
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
    try std.testing.expectEqualStrings("rule no-console { override }", override_source.?);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "load: project_dir overrides user_dir silently" {
    var user_tmp = std.testing.tmpDir(.{});
    defer user_tmp.cleanup();
    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();

    try user_tmp.dir.createDirPath(std.testing.io, "go");
    try user_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "go/no-panic.kata",
        .data = "rule no-panic { user }",
    });
    try project_tmp.dir.createDirPath(std.testing.io, "go");
    try project_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "go/no-panic.kata",
        .data = "rule no-panic { project }",
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
    try std.testing.expectEqualStrings("rule no-panic { project }", set.get(.go)[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "upsertProject: same-tier collision warns with the project scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsertProject(.{ .id = "isolation", .source = "1" }, .user);
    try set.upsertProject(.{ .id = "isolation", .source = "2" }, .user);

    try std.testing.expectEqual(@as(usize, 1), set.projectRaws().len);
    try std.testing.expectEqualStrings("2", set.projectRaws()[0].source);
    try std.testing.expectEqual(@as(usize, 1), set.warnings.items.len);
    try std.testing.expectEqual(@as(?language.Name, null), set.warnings.items[0].lang);
    try std.testing.expectEqualStrings("isolation", set.warnings.items[0].id);
}

test "upsertProject: project tier overrides user tier silently" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: loader.RuleSet = .{ .allocator = arena.allocator() };

    try set.upsertProject(.{ .id = "isolation", .source = "1" }, .user);
    try set.upsertProject(.{ .id = "isolation", .source = "2" }, .project);

    try std.testing.expectEqual(@as(usize, 1), set.projectRaws().len);
    try std.testing.expectEqualStrings("2", set.projectRaws()[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

test "load: project dir reads kata files into the project slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/isolation.kata",
        .data = "rule isolation {}",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path_buf: [256]u8 = undefined;
    const rel = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var set = try loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .project_dir = rel,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), set.projectRaws().len);
    try std.testing.expectEqualStrings("isolation", set.projectRaws()[0].id);
    try std.testing.expectEqualStrings("rule isolation {}", set.projectRaws()[0].source);
    try std.testing.expectEqual(loader.Source.project, set.projectRaws()[0].origin);
}

test "load: project dir ignores non-kata files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/isolation.scm",
        .data = "((identifier) @match)",
    });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path_buf: [256]u8 = undefined;
    const rel = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var set = try loader.load(arena.allocator(), std.testing.io, .{
        .skip_embedded = true,
        .project_dir = rel,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), set.projectRaws().len);
}

test "load: project tier project rule overrides the user tier" {
    var user_tmp = std.testing.tmpDir(.{});
    defer user_tmp.cleanup();
    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();

    try user_tmp.dir.createDirPath(std.testing.io, "project");
    try user_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/isolation.kata",
        .data = "rule isolation { severity warn }",
    });
    try project_tmp.dir.createDirPath(std.testing.io, "project");
    try project_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/isolation.kata",
        .data = "rule isolation {}",
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

    try std.testing.expectEqual(@as(usize, 1), set.projectRaws().len);
    try std.testing.expectEqualStrings("rule isolation {}", set.projectRaws()[0].source);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.items.len);
}

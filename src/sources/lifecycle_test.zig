const std = @import("std");

const lint = @import("engine");
const lifecycle = @import("lifecycle.zig");
const loader = @import("loader.zig");

const diagnostic = lint.diagnostic;

fn localRule(comptime id: []const u8, comptime clauses: []const u8) []const u8 {
    return "rule " ++ id ++ " {\n" ++ clauses ++
        "  lang ts\n" ++
        "  match identifier @id\n" ++
        "  emit @id { message \"m\" }\n" ++
        "}\n";
}

test "lifecycle: builds alias and maturity table from rule bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "new-name", .source = localRule("new-name", "  former-ids old-name, \"older-name\"\n  maturity deprecated\n") });
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    var diag: lint.rule.Diagnostic = .{};
    const table = try lifecycle.build(arena, &rule_set, &diag);

    try std.testing.expectEqual(diagnostic.Maturity.deprecated, table.maturityOf(.ts, "new-name"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "plain"));

    switch (table.resolve(.ts, "old-name")) {
        .renamed => |canonical| try std.testing.expectEqualStrings("new-name", canonical),
        else => return error.TestUnexpectedResult,
    }
    switch (table.resolve(.ts, "older-name")) {
        .renamed => |canonical| try std.testing.expectEqualStrings("new-name", canonical),
        else => return error.TestUnexpectedResult,
    }
}

test "lifecycle: resolve returns unchanged for live and unknown ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    var diag: lint.rule.Diagnostic = .{};
    const table = try lifecycle.build(arena, &rule_set, &diag);

    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.ts, "plain"));
    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.ts, "missing"));
    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.go, "plain"));
}

test "lifecycle: parse-failing body is skipped without error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "broken", .source = "rule broken {" });
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    var diag: lint.rule.Diagnostic = .{};
    const table = try lifecycle.build(arena, &rule_set, &diag);

    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.ts, "broken"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "broken"));
    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.ts, "plain"));
}

test "lifecycle: former id colliding with a live id fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "renamed", .source = localRule("renamed", "  former-ids plain\n") });
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    var diag: lint.rule.Diagnostic = .{};
    try std.testing.expectError(error.LifecycleCollision, lifecycle.build(arena, &rule_set, &diag));
    try std.testing.expectEqual(lint.language.Name.ts, diag.lang.?);
    try std.testing.expectEqualStrings("renamed", diag.rule_id);
    try std.testing.expectEqualStrings("former id 'plain' is a live rule id", diag.detail);
}

test "lifecycle: former id claimed by two rules fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "first", .source = localRule("first", "  former-ids shared-old\n") });
    try rule_set.append(.ts, .{ .id = "second", .source = localRule("second", "  former-ids shared-old\n") });

    var diag: lint.rule.Diagnostic = .{};
    try std.testing.expectError(error.LifecycleCollision, lifecycle.build(arena, &rule_set, &diag));
    try std.testing.expectEqual(lint.language.Name.ts, diag.lang.?);
    try std.testing.expectEqualStrings("second", diag.rule_id);
    try std.testing.expectEqualStrings("former id 'shared-old' already claimed by rule 'first'", diag.detail);
}

test "lifecycle: same former id in different scopes is allowed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "ts-rule", .source = localRule("ts-rule", "  former-ids shared-old\n") });
    try rule_set.append(.go, .{ .id = "go-rule", .source = localRule("go-rule", "  former-ids shared-old\n") });

    var diag: lint.rule.Diagnostic = .{};
    const table = try lifecycle.build(arena, &rule_set, &diag);

    switch (table.resolve(.ts, "shared-old")) {
        .renamed => |canonical| try std.testing.expectEqualStrings("ts-rule", canonical),
        else => return error.TestUnexpectedResult,
    }
    switch (table.resolve(.go, "shared-old")) {
        .renamed => |canonical| try std.testing.expectEqualStrings("go-rule", canonical),
        else => return error.TestUnexpectedResult,
    }
}

test "lifecycle: project rules register in the project scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.project.append(arena, .{ .id = "boundary", .source = "rule boundary {\n" ++
        "  kind project\n" ++
        "  former-ids old-boundary\n" ++
        "  match import @import\n" ++
        "  where { field(@import, source) == \"legacy\" }\n" ++
        "  emit @import { message \"m\" }\n" ++
        "}\n" });

    var diag: lint.rule.Diagnostic = .{};
    const table = try lifecycle.build(arena, &rule_set, &diag);

    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(null, "boundary"));
    switch (table.resolve(null, "old-boundary")) {
        .renamed => |canonical| try std.testing.expectEqualStrings("boundary", canonical),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(lifecycle.Resolution.unchanged, table.resolve(.ts, "old-boundary"));
}

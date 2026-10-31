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

test "lifecycle: builds the maturity table from rule bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "preview", .source = localRule("preview", "  maturity experimental\n") });
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    const table = try lifecycle.build(arena, &rule_set);

    try std.testing.expectEqual(diagnostic.Maturity.experimental, table.maturityOf(.ts, "preview"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "plain"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.go, "preview"));
}

test "lifecycle: parse-failing body is skipped without error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.append(.ts, .{ .id = "broken", .source = "rule broken {" });
    try rule_set.append(.ts, .{ .id = "plain", .source = localRule("plain", "") });

    const table = try lifecycle.build(arena, &rule_set);

    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "broken"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "plain"));
}

test "lifecycle: project rules register in the project scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = loader.RuleSet{ .allocator = arena };
    try rule_set.project.append(arena, .{ .id = "boundary", .source = "rule boundary {\n" ++
        "  kind project\n" ++
        "  maturity experimental\n" ++
        "  match import @import\n" ++
        "  where { field(@import, source) == \"legacy\" }\n" ++
        "  emit @import { message \"m\" }\n" ++
        "}\n" });

    const table = try lifecycle.build(arena, &rule_set);

    try std.testing.expectEqual(diagnostic.Maturity.experimental, table.maturityOf(null, "boundary"));
    try std.testing.expectEqual(diagnostic.Maturity.stable, table.maturityOf(.ts, "boundary"));
}

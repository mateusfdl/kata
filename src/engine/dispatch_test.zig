const std = @import("std");

const dsl = @import("dsl");
const dispatch = @import("engine").dispatch;
const family = @import("engine").family;
const OwnedArena = @import("shared").owned_arena.OwnedArena;
const query = @import("engine").query;
const root_kind_set = @import("engine").root_kind_set;
const rule = @import("engine").rule;
const rule_compiler = @import("engine").rule_compiler;
const TableMemory = @import("shared").table_memory.TableMemory;
const test_fixture = @import("../test_fixture.zig");

const Engine = @import("engine").Engine;
const RuleSet = @import("engine").RuleSet;

fn rootKinds(arena: std.mem.Allocator, kind: query.Kind) root_kind_set.Error![]const u16 {
    return root_kind_set.derive(arena, &.{ .kind = kind });
}

fn compiledPattern(arena: std.mem.Allocator, rule_id: []const u8, kind: query.Kind) !rule.CompiledPattern {
    return .{
        .pattern = .{ .kind = kind },
        .capture_count = 0,
        .match_capture_id = null,
        .meta = .{
            .predicates = try arena.alloc(rule.Predicate, 0),
            .message = null,
            .rule_id = rule_id,
        },
    };
}

test "rootKinds resolves a concrete symbol to a singleton" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .symbol = 42 });
    try std.testing.expectEqualSlices(u16, &.{42}, kinds);
}

test "rootKinds resolves an anonymous token to a singleton" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .anonymous = 200 });
    try std.testing.expectEqualSlices(u16, &.{200}, kinds);
}

test "rootKinds passes a supertype set through sorted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .symbols = &.{ 3, 7, 11 } });
    try std.testing.expectEqualSlices(u16, &.{ 3, 7, 11 }, kinds);
}

test "rootKinds unions alternation branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .alternation = &.{
        .{ .kind = .{ .symbol = 9 } },
        .{ .kind = .{ .symbol = 4 } },
    } });
    try std.testing.expectEqualSlices(u16, &.{ 4, 9 }, kinds);
}

test "rootKinds flattens nested alternations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .alternation = &.{
        .{ .kind = .{ .symbol = 15 } },
        .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbols = &.{ 2, 8 } } },
            .{ .kind = .{ .anonymous = 190 } },
        } } },
    } });
    try std.testing.expectEqualSlices(u16, &.{ 2, 8, 15, 190 }, kinds);
}

test "rootKinds dedups kinds shared across branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try rootKinds(arena.allocator(), .{ .alternation = &.{
        .{ .kind = .{ .symbols = &.{ 5, 6 } } },
        .{ .kind = .{ .symbol = 6 } },
        .{ .kind = .{ .symbol = 5 } },
    } });
    try std.testing.expectEqualSlices(u16, &.{ 5, 6 }, kinds);
}

test "rootKinds fails on an empty alternation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.EmptyRootKinds,
        rootKinds(arena.allocator(), .{ .alternation = &.{} }),
    );
}

test "Table.build orders a shared slot by rule id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = TableMemory.init(a, std.testing.allocator);
    defer memory.deinit();

    const patterns = [_]rule.CompiledPattern{
        try compiledPattern(a, "b-rule", .{ .symbol = 7 }),
        try compiledPattern(a, "a-rule", .{ .symbol = 7 }),
    };

    const table = try dispatch.Table.buildWithMemory(&memory, &patterns, 10);

    try std.testing.expectEqual(@as(usize, 10), table.keyCount());
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, table.get(7));
    try std.testing.expectEqualSlices(usize, &.{}, table.get(0));
    try std.testing.expectEqualSlices(usize, &.{}, table.get(3));
}

test "Table.build registers a supertype set in every member slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = TableMemory.init(a, std.testing.allocator);
    defer memory.deinit();

    const patterns = [_]rule.CompiledPattern{
        try compiledPattern(a, "super-rule", .{ .symbols = &.{ 3, 5 } }),
    };

    const table = try dispatch.Table.buildWithMemory(&memory, &patterns, 6);

    try std.testing.expectEqualSlices(usize, &.{0}, table.get(3));
    try std.testing.expectEqualSlices(usize, &.{0}, table.get(5));
    try std.testing.expectEqualSlices(usize, &.{}, table.get(4));
}

test "Table.build registers an alternation in each branch slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = TableMemory.init(a, std.testing.allocator);
    defer memory.deinit();

    const patterns = [_]rule.CompiledPattern{
        try compiledPattern(a, "alt-rule", .{ .alternation = &.{
            .{ .kind = .{ .symbol = 2 } },
            .{ .kind = .{ .symbol = 9 } },
        } }),
    };

    const table = try dispatch.Table.buildWithMemory(&memory, &patterns, 12);

    try std.testing.expectEqualSlices(usize, &.{0}, table.get(2));
    try std.testing.expectEqualSlices(usize, &.{0}, table.get(9));
}

test "PatternIndex dispatches only eligible patterns in static order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var memory = TableMemory.init(arena.allocator(), std.testing.allocator);
    defer memory.deinit();

    const patterns = [_]query.Pattern{
        .{ .kind = .{ .symbol = 3 } },
        .{ .kind = .{ .symbol = 7 } },
        .{ .kind = .{ .alternation = &.{
            .{ .kind = .{ .symbol = 3 } },
            .{ .kind = .{ .symbol = 5 } },
        } } },
    };
    const index = try dispatch.PatternIndex.buildWithMemory(
        &memory,
        &patterns,
        8,
    );

    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, index.get(3));
    try std.testing.expectEqualSlices(usize, &.{2}, index.get(5));
    try std.testing.expectEqualSlices(usize, &.{1}, index.get(7));
    try std.testing.expectEqualSlices(usize, &.{}, index.get(4));
}

test "PatternIndex supports more than u16 pattern indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var memory = TableMemory.init(arena.allocator(), std.testing.allocator);
    defer memory.deinit();

    const pattern_count: usize = @as(usize, std.math.maxInt(u16)) + 2;
    const patterns = try arena.allocator().alloc(query.Pattern, pattern_count);
    for (patterns) |*pattern| pattern.* = .{ .kind = .{ .symbol = 1 } };

    const index = try dispatch.PatternIndex.buildWithMemory(&memory, patterns, 2);

    try std.testing.expectEqual(@as(usize, pattern_count), index.get(1).len);
    for (index.get(1), 0..) |pattern_index, expected| {
        try std.testing.expectEqual(expected, pattern_index);
    }
}

test "Table.build propagates an underivable pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = TableMemory.init(a, std.testing.allocator);
    defer memory.deinit();

    const patterns = [_]rule.CompiledPattern{
        try compiledPattern(a, "broken", .{ .alternation = &.{} }),
    };

    try std.testing.expectError(error.EmptyRootKinds, dispatch.Table.buildWithMemory(&memory, &patterns, 4));
}

test "Table.build indexes a dsl compiled rule under its head kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = TableMemory.init(a, std.testing.allocator);
    defer memory.deinit();

    var diag: rule.Diagnostic = .{};
    const raws = [_]rule.RawRule{.{ .id = "no-as-any", .source = test_fixture.no_as_any_rule }};
    var compiled = (try dsl.engine_compiler.ruleCompiler().compileLang(std.testing.allocator, .ts, &raws, &diag)).?;
    defer compiled.deinit();

    const adapter = family.of(.ts_family);
    const table = try dispatch.Table.buildWithMemory(&memory, compiled.patterns, adapter.kind_count);
    const as_expression = adapter.kindId("as_expression", true);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, table.get(as_expression));
    try std.testing.expectEqualSlices(usize, &.{}, table.get(adapter.kindId("call_expression", true)));
}

fn brokenCompileLang(
    allocator: std.mem.Allocator,
    lang: @import("engine").language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) rule_compiler.CompileError!?rule.CompiledRule {
    _ = raws;
    _ = diag;
    if (lang != .ts) return null;

    const owned_arena = try OwnedArena.create(allocator);
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const patterns = try a.alloc(rule.CompiledPattern, 1);
    patterns[0] = try compiledPattern(a, "broken", .{ .alternation = &.{} });

    return .{
        .patterns = patterns,
        .needs_measures = false,
        .arena = owned_arena,
    };
}

fn emptyCompileFacts(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) rule_compiler.CompileError![]const @import("engine").fact_rule.CompiledFactRule {
    _ = output_allocator;
    _ = scratch_allocator;
    _ = raws;
    _ = diag;
    return &.{};
}

test "engine reports an underivable rule as a compile failure on every attempt" {
    const gpa = std.testing.allocator;

    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &rule_set, .{
        .compileLang = brokenCompileLang,
        .compileFacts = emptyCompileFacts,
    }, &.{});
    defer engine.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectEqual(false, try engine.prewarmOrReport("kata", &out.writer));
    try std.testing.expectEqualStrings("kata: rule ts/broken: cannot derive root kinds\n", out.written());

    var retry_out: std.Io.Writer.Allocating = .init(gpa);
    defer retry_out.deinit();

    try std.testing.expectEqual(false, try engine.prewarmOrReport("kata", &retry_out.writer));
    try std.testing.expectEqualStrings("kata: rule ts/broken: cannot derive root kinds\n", retry_out.written());
}

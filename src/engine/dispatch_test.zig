const std = @import("std");

const dispatch = @import("engine").dispatch;
const query = @import("engine").query;

fn rootKinds(arena: std.mem.Allocator, kind: query.Kind) dispatch.Error![]const u16 {
    return dispatch.rootKinds(arena, &.{ .kind = kind });
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

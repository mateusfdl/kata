const std = @import("std");

const query = @import("query.zig");
const rule = @import("rule.zig");

pub const Error = error{EmptyRootKinds} || std.mem.Allocator.Error;

pub const Table = struct {
    slots: []const []const u16,

    pub const empty: Table = .{ .slots = &.{} };

    pub fn build(
        arena: std.mem.Allocator,
        allocator: std.mem.Allocator,
        patterns: []const rule.CompiledPattern,
        kind_count: u16,
    ) Error!Table {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();

        const lists = try temporary.alloc(std.ArrayList(u16), kind_count);
        @memset(lists, .empty);

        for (patterns, 0..) |cp, index| {
            const kinds = try rootKinds(temporary, &cp.pattern);
            for (kinds) |kind| {
                try lists[kind].append(temporary, @intCast(index));
            }
        }

        const slots = try arena.alloc([]const u16, kind_count);
        for (lists, slots) |*list, *slot| {
            const entries = try arena.dupe(u16, list.items);
            std.sort.pdq(u16, entries, patterns, patternBefore);
            slot.* = entries;
        }

        return .{ .slots = slots };
    }
};

fn patternBefore(patterns: []const rule.CompiledPattern, a: u16, b: u16) bool {
    return switch (std.mem.order(u8, patterns[a].meta.rule_id, patterns[b].meta.rule_id)) {
        .lt => true,
        .gt => false,
        .eq => a < b,
    };
}

pub fn rootKinds(arena: std.mem.Allocator, pattern: *const query.Pattern) Error![]const u16 {
    var kinds: std.ArrayList(u16) = .empty;
    try collectKinds(arena, &kinds, pattern.kind);
    if (kinds.items.len == 0) return error.EmptyRootKinds;
    std.sort.pdq(u16, kinds.items, {}, std.sort.asc(u16));
    var unique: usize = 0;
    for (kinds.items) |kind| {
        if (unique > 0 and kinds.items[unique - 1] == kind) continue;
        kinds.items[unique] = kind;
        unique += 1;
    }
    return kinds.items[0..unique];
}

fn collectKinds(arena: std.mem.Allocator, kinds: *std.ArrayList(u16), kind: query.Kind) Error!void {
    switch (kind) {
        .symbol, .anonymous => |id| try kinds.append(arena, id),
        .symbols => |ids| try kinds.appendSlice(arena, ids),
        .alternation => |branches| for (branches) |branch| {
            try collectKinds(arena, kinds, branch.kind);
        },
    }
}

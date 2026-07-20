const std = @import("std");

const query = @import("query.zig");

pub const Error = error{EmptyRootKinds} || std.mem.Allocator.Error;

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

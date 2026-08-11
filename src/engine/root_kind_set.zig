const std = @import("std");

const query = @import("query.zig");
const sorted_slice = @import("shared").sorted_slice;

const SortedKinds = sorted_slice.Type(u16, lessThan);

pub const Error = error{EmptyRootKinds} || std.mem.Allocator.Error;

pub fn derive(allocator: std.mem.Allocator, pattern: *const query.Pattern) Error![]const u16 {
    var kinds: std.ArrayList(u16) = .empty;
    errdefer kinds.deinit(allocator);

    try collect(allocator, &kinds, pattern.kind);
    if (kinds.items.len == 0) return error.EmptyRootKinds;

    const unique = SortedKinds.sortUnique(kinds.items);
    kinds.items.len = unique.len;
    return kinds.toOwnedSlice(allocator);
}

fn collect(allocator: std.mem.Allocator, kinds: *std.ArrayList(u16), kind: query.Kind) std.mem.Allocator.Error!void {
    switch (kind) {
        .symbol, .anonymous => |id| try kinds.append(allocator, id),
        .symbols => |ids| try kinds.appendSlice(allocator, ids),
        .alternation => |branches| for (branches) |branch| {
            try collect(allocator, kinds, branch.kind);
        },
    }
}

fn lessThan(a: u16, b: u16) bool {
    return a < b;
}

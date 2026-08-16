const std = @import("std");

const context_query = @import("context_query.zig");
const operand_query = @import("operand_query.zig");

const BoundFact = context_query.BoundFact;
const Context = context_query.Context;

pub const MessageSegment = union(enum) {
    literal: []const u8,
    operand: operand_query.Operand,
};

pub fn render(
    allocator: std.mem.Allocator,
    segments: []const MessageSegment,
    ctx: Context,
    bindings: []?BoundFact,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(allocator, text),
            .operand => |operand| {
                const value = (try operand.resolve(ctx, bindings)) orelse "?";
                try out.appendSlice(allocator, value);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

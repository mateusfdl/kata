const std = @import("std");

const group_index = @import("group_index.zig");

pub fn Type(
    comptime Item: type,
    comptime Key: type,
    comptime Context: type,
    comptime Callbacks: type,
) type {
    return struct {
        const Groups = group_index.Type(Key, Item, Context);

        pub fn apply(
            arena: std.mem.Allocator,
            items: []const Item,
            context: Context,
            callbacks: Callbacks,
            overflow_shown: usize,
        ) ![]Item {
            if (overflow_shown == 0) {
                return error.InvalidOverflowShown;
            }

            const entries = try arena.alloc(Groups.Entry, items.len);

            for (items, entries) |item, *entry| {
                entry.* = .{
                    .key = callbacks.key(item),
                    .value = item,
                };
            }

            const groups = try Groups.build(arena, entries, context);
            const shown = try arena.alloc(usize, groups.groupCount());

            @memset(shown, 0);

            var out: std.ArrayList(Item) = .empty;
            for (items) |item| {
                const key = callbacks.key(item);
                const group_number = groups.indexOf(key);

                std.debug.assert(group_number != null);

                const index = group_number.?;
                const group = groups.getByIndex(index);
                const total = group.len;

                std.debug.assert(shown[index] <= total);

                const cap = callbacks.cap(key);
                if (cap == 0 or total <= cap) {
                    try out.append(arena, item);

                    continue;
                }

                const show = @min(overflow_shown, total);
                if (shown[index] >= show) continue;

                shown[index] += 1;

                std.debug.assert(shown[index] <= total);
                try out.append(arena, item);

                if (shown[index] == show) {
                    try out.append(arena, try callbacks.overflow(arena, group[0], total, show));
                }
            }

            return out.toOwnedSlice(arena);
        }
    };
}

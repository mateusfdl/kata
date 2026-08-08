const std = @import("std");

pub fn Type(
    comptime Key: type,
    comptime Value: type,
    comptime Context: type,
) type {
    return struct {
        keys: []const Key,
        offsets: []const usize,
        values: []const Value,
        groups: Map,
        context: Context,

        const Self = @This();
        const Map = std.HashMapUnmanaged(Key, usize, Context, 80);

        pub const Entry = struct {
            key: Key,
            value: Value,
        };

        pub fn build(
            arena: std.mem.Allocator,
            entries: []const Entry,
            context: Context,
        ) std.mem.Allocator.Error!Self {
            var groups: Map = .empty;
            var keys: std.ArrayList(Key) = .empty;
            var counts: std.ArrayList(usize) = .empty;

            for (entries) |entry| {
                const gop = try groups.getOrPutContext(arena, entry.key, context);
                if (!gop.found_existing) {
                    gop.value_ptr.* = keys.items.len;

                    try keys.append(arena, entry.key);
                    try counts.append(arena, 0);
                }

                counts.items[gop.value_ptr.*] += 1;
            }

            const offsets = try arena.alloc(usize, keys.items.len + 1);
            offsets[0] = 0;

            for (counts.items, 0..) |count, index| {
                offsets[index + 1] = offsets[index] + count;
            }

            const cursors = try arena.dupe(usize, offsets[0..keys.items.len]);
            const values = try arena.alloc(Value, entries.len);

            for (entries) |entry| {
                const group = groups.getContext(entry.key, context);
                std.debug.assert(group != null);

                const group_index = group.?;

                values[cursors[group_index]] = entry.value;
                cursors[group_index] += 1;
            }

            return .{
                .keys = try keys.toOwnedSlice(arena),
                .offsets = offsets,
                .values = values,
                .groups = groups,
                .context = context,
            };
        }

        pub fn groupCount(self: Self) usize {
            return self.keys.len;
        }

        pub fn indexOf(self: Self, key: Key) ?usize {
            return self.groups.getContext(key, self.context);
        }

        pub fn getByIndex(self: Self, index: usize) []const Value {
            std.debug.assert(index < self.groupCount());
            return self.values[self.offsets[index]..self.offsets[index + 1]];
        }

        pub fn get(self: Self, key: Key) []const Value {
            const index = self.indexOf(key) orelse return &.{};

            return self.getByIndex(index);
        }
    };
}

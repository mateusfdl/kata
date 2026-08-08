const std = @import("std");
const TableMemory = @import("table_memory.zig").TableMemory;

pub fn DenseMultiMapType(comptime Value: type) type {
    return struct {
        offsets: []const usize,
        values: []const Value,

        const Self = @This();

        pub const Entry = struct {
            key: usize,
            value: Value,
        };

        pub const BuildError = error{KeyOutOfRange} || std.mem.Allocator.Error;
        pub const empty: Self = .{ .offsets = &.{0}, .values = &.{} };

        pub fn build(
            memory: *TableMemory,
            key_count: usize,
            entries: []const Entry,
        ) BuildError!Self {
            std.debug.assert(key_count < std.math.maxInt(usize));

            const counts = try memory.scratch().alloc(usize, key_count);
            @memset(counts, 0);

            for (entries) |entry| {
                if (entry.key >= key_count) return error.KeyOutOfRange;
                std.debug.assert(entry.key < key_count);
                counts[entry.key] += 1;
            }

            const offsets = try memory.output().alloc(usize, key_count + 1);
            errdefer memory.output().free(offsets);
            offsets[0] = 0;
            for (counts, 0..) |count, key| {
                offsets[key + 1] = offsets[key] + count;
                std.debug.assert(offsets[key] <= offsets[key + 1]);
                std.debug.assert(offsets[key + 1] <= entries.len);
            }
            std.debug.assert(offsets[key_count] == entries.len);

            const cursors = try memory.scratch().dupe(usize, offsets[0..key_count]);

            const values = try memory.output().alloc(Value, entries.len);
            for (entries) |entry| {
                std.debug.assert(cursors[entry.key] < offsets[entry.key + 1]);
                std.debug.assert(cursors[entry.key] < values.len);
                values[cursors[entry.key]] = entry.value;
                cursors[entry.key] += 1;
            }
            for (cursors, 0..) |cursor, key| {
                std.debug.assert(cursor == offsets[key + 1]);
            }

            return .{ .offsets = offsets, .values = values };
        }

        pub fn keyCount(self: Self) usize {
            return self.offsets.len - 1;
        }

        pub fn get(self: Self, key: usize) []const Value {
            if (key >= self.keyCount()) return &.{};
            return self.values[self.offsets[key]..self.offsets[key + 1]];
        }
    };
}

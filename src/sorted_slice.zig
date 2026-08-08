const std = @import("std");

pub fn Type(
    comptime T: type,
    comptime lessThan: fn (T, T) bool,
) type {
    return struct {
        pub fn upperBound(items: []const T, key: T) usize {
            assertSorted(items);

            var low: usize = 0;
            var high = items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (!lessThan(key, items[middle])) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }

            return low;
        }

        pub fn contains(items: []const T, key: T) bool {
            const end = upperBound(items, key);
            return end > 0 and equivalent(items[end - 1], key);
        }

        pub fn sortUnique(items: []T) []T {
            std.sort.pdq(T, items, {}, order);
            if (items.len < 2) return items;

            var unique: usize = 1;
            for (items[1..]) |item| {
                if (equivalent(items[unique - 1], item)) continue;
                items[unique] = item;
                unique += 1;
            }

            return items[0..unique];
        }

        fn assertSorted(items: []const T) void {
            if (items.len < 2) return;
            for (items[1..], 1..) |item, index| {
                std.debug.assert(!lessThan(item, items[index - 1]));
            }
        }

        fn equivalent(a: T, b: T) bool {
            return !lessThan(a, b) and !lessThan(b, a);
        }

        fn order(_: void, a: T, b: T) bool {
            return lessThan(a, b);
        }
    };
}

const std = @import("std");

pub fn Selector(
    comptime Item: type,
    comptime Range: type,
    comptime intervalOf: fn (Item) Range,
) type {
    return struct {
        pub fn innermost(items: []const Item, target: Range) ?usize {
            var best: ?usize = null;

            for (items, 0..) |item, index| {
                const candidate = intervalOf(item);
                if (!candidate.strictlyContains(target)) continue;

                if (best) |best_index| {
                    const current = intervalOf(items[best_index]);
                    std.debug.assert(current.containsInterval(candidate) or candidate.containsInterval(current));

                    if (!current.strictlyContains(candidate)) continue;
                }

                best = index;
            }

            return best;
        }

        pub fn sweepInnermost(allocator: std.mem.Allocator, items: []const Item) std.mem.Allocator.Error![]?usize {
            assertParentBeforeChild(items);

            const owners = try allocator.alloc(?usize, items.len);
            errdefer allocator.free(owners);

            var stack: std.ArrayList(usize) = .empty;
            defer stack.deinit(allocator);

            for (items, 0..) |item, index| {
                const current = intervalOf(item);
                while (stack.items.len > 0 and intervalOf(items[stack.items[stack.items.len - 1]]).endsBefore(current)) {
                    _ = stack.pop();
                }

                if (stack.items.len > 0) {
                    const open = intervalOf(items[stack.items[stack.items.len - 1]]);
                    std.debug.assert(open.containsInterval(current));
                }

                owners[index] = null;
                var open_index = stack.items.len;
                while (open_index > 0) {
                    open_index -= 1;
                    const candidate_index = stack.items[open_index];
                    if (!intervalOf(items[candidate_index]).strictlyContains(current)) continue;
                    owners[index] = candidate_index;
                    break;
                }

                try stack.append(allocator, index);
            }

            return owners;
        }

        fn assertParentBeforeChild(items: []const Item) void {
            if (items.len < 2) return;
            for (items[1..], 1..) |item, index| {
                const previous = intervalOf(items[index - 1]);
                const current = intervalOf(item);
                std.debug.assert(previous.start < current.start or
                    (previous.start == current.start and current.end <= previous.end));
            }
        }
    };
}

const std = @import("std");

const node_pool = @import("node_pool.zig");

test "node pool returns aligned stable nodes and reports exhaustion" {
    const Pool = node_pool.NodePoolType(32, 16);
    var pool = try Pool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var nodes: [4]Pool.Node = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = pool.acquire().?;
        try std.testing.expect(std.mem.Alignment.fromByteUnits(16).check(@intFromPtr(node.*)));
        @memset(node.*, @as(u8, @intCast(index + 1)));
    }

    try std.testing.expectEqual(@as(?Pool.Node, null), pool.acquire());
    try std.testing.expectEqual(@as(usize, 4), pool.inUseCount());
    for (nodes, 0..) |node, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), node[0]);
        pool.release(node);
    }
    try std.testing.expectEqual(@as(usize, 4), pool.available());
}

test "node pool agrees with an allocation model" {
    const Pool = node_pool.NodePoolType(64, 32);
    const capacity = 31;
    var pool = try Pool.init(std.testing.allocator, capacity);
    defer pool.deinit();

    var model = [_]?Pool.Node{null} ** capacity;
    var prng = std.Random.DefaultPrng.init(0xb329a4d1);
    const random = prng.random();
    var expected_in_use: usize = 0;

    for (0..4_000) |_| {
        if (random.boolean()) {
            const node = pool.acquire();
            if (expected_in_use == capacity) {
                try std.testing.expectEqual(@as(?Pool.Node, null), node);
            } else {
                const acquired = node.?;
                const index = (@intFromPtr(acquired) - @intFromPtr(pool.regionPointer())) / Pool.node_size;
                try std.testing.expectEqual(@as(?Pool.Node, null), model[index]);
                model[index] = acquired;
                expected_in_use += 1;
            }
        } else if (expected_in_use != 0) {
            var index = random.uintLessThan(usize, capacity);
            while (model[index] == null) index = (index + 1) % capacity;
            pool.release(model[index].?);
            model[index] = null;
            expected_in_use -= 1;
        }

        try std.testing.expectEqual(expected_in_use, pool.inUseCount());
        try std.testing.expectEqual(capacity - expected_in_use, pool.available());
    }

    for (&model) |*entry| {
        if (entry.*) |node| pool.release(node);
        entry.* = null;
    }
}

test "node pool rejects zero capacity" {
    const Pool = node_pool.NodePoolType(16, 8);
    try std.testing.expectError(error.InvalidCapacity, Pool.init(std.testing.allocator, 0));
}

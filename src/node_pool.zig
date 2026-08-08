const std = @import("std");

pub fn NodePoolType(comptime node_size_value: usize, comptime alignment_value: usize) type {
    comptime {
        std.debug.assert(node_size_value > 0);
        std.debug.assert(std.math.isPowerOfTwo(alignment_value));
        std.debug.assert(node_size_value % alignment_value == 0);
    }

    return struct {
        allocator: std.mem.Allocator,
        region: []align(alignment_value) u8,
        free: std.DynamicBitSetUnmanaged,
        in_use_count: usize = 0,

        pub const node_size = node_size_value;
        pub const alignment = alignment_value;
        pub const Node = *align(alignment_value) [node_size_value]u8;

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, node_count: usize) (std.mem.Allocator.Error || error{InvalidCapacity})!Self {
            if (node_count == 0) return error.InvalidCapacity;
            const region_size = std.math.mul(usize, node_size_value, node_count) catch return error.InvalidCapacity;
            const region = try allocator.alignedAlloc(
                u8,
                std.mem.Alignment.fromByteUnits(alignment_value),
                region_size,
            );
            errdefer allocator.free(region);

            // A set bit means available. Nodes are offsets into one region, so
            // their addresses stay stable until the pool is destroyed.
            const free = try std.DynamicBitSetUnmanaged.initFull(allocator, node_count);
            return .{
                .allocator = allocator,
                .region = region,
                .free = free,
            };
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            // Live node pointers would become dangling when the region is freed.
            // Require clients to release all nodes instead of hiding that bug.
            std.debug.assert(self.in_use_count == 0);
            self.allocator.free(self.region);
            self.free.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn acquire(self: *Self) ?Node {
            self.assertInvariants();
            const index = self.free.findFirstSet() orelse return null;
            self.free.unset(index);
            self.in_use_count += 1;
            self.assertInvariants();

            // init validates that each node-sized stride preserves alignment.
            const bytes = self.region[index * node_size_value ..][0..node_size_value];
            return @ptrCast(@alignCast(bytes.ptr));
        }

        pub fn release(self: *Self, node: Node) void {
            self.assertInvariants();
            const start = @intFromPtr(self.region.ptr);
            const address = @intFromPtr(node);
            const end = start + self.region.len;
            std.debug.assert(address >= start);
            std.debug.assert(address <= end - node_size_value);

            // Membership and stride checks reject foreign and interior pointers.
            // An unset bit also rejects a double release.
            const offset = address - start;
            std.debug.assert(offset % node_size_value == 0);
            const index = offset / node_size_value;
            std.debug.assert(!self.free.isSet(index));

            self.free.set(index);
            self.in_use_count -= 1;
            self.assertInvariants();
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.free.capacity();
        }

        pub fn available(self: *const Self) usize {
            self.assertInvariants();
            return self.free.count();
        }

        pub fn inUseCount(self: *const Self) usize {
            self.assertInvariants();
            return self.in_use_count;
        }

        pub fn regionPointer(self: *Self) [*]align(alignment_value) u8 {
            return self.region.ptr;
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.region.len == self.free.capacity() * node_size_value);
            std.debug.assert(self.in_use_count <= self.free.capacity());
            std.debug.assert(self.free.count() + self.in_use_count == self.free.capacity());
        }
    };
}

const std = @import("std");

pub const StackLink = extern struct {
    next: ?*StackLink = null,
};

pub fn StackType(comptime T: type) type {
    return struct {
        head: ?*StackLink = null,
        count_value: usize = 0,
        capacity_value: usize,

        pub const Link = StackLink;

        const Self = @This();

        pub fn init(capacity_value: usize) Self {
            return .{ .capacity_value = capacity_value };
        }

        pub fn count(self: *const Self) usize {
            self.assertInvariants();
            return self.count_value;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();
            return self.capacity_value;
        }

        pub fn empty(self: *const Self) bool {
            self.assertInvariants();
            return self.count_value == 0;
        }

        pub fn push(self: *Self, node: *T) void {
            self.assertInvariants();
            std.debug.assert(self.count_value < self.capacity_value);
            std.debug.assert(node.link.next == null);
            std.debug.assert(!self.contains(node));

            node.link.next = self.head;
            self.head = &node.link;
            self.count_value += 1;
            self.assertInvariants();
        }

        pub fn pop(self: *Self) *T {
            std.debug.assert(!self.empty());
            return self.popOrNull().?;
        }

        pub fn popOrNull(self: *Self) ?*T {
            self.assertInvariants();
            const link = self.head orelse return null;
            self.head = link.next;

            link.next = null;
            self.count_value -= 1;
            self.assertInvariants();

            return @alignCast(@fieldParentPtr("link", link));
        }

        pub fn peek(self: *const Self) *T {
            self.assertInvariants();
            std.debug.assert(self.head != null);

            return @alignCast(@fieldParentPtr("link", self.head.?));
        }

        fn contains(self: *const Self, node: *const T) bool {
            var link = self.head;
            for (0..self.count_value) |_| {
                const current = link orelse unreachable;
                if (current == &node.link) {
                    return true;
                }

                link = current.next;
            }
            std.debug.assert(link == null);

            return false;
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.count_value <= self.capacity_value);
            std.debug.assert((self.count_value == 0) == (self.head == null));
        }
    };
}

pub fn ValueStackType(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        values: []T,
        count_value: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity_value: usize) std.mem.Allocator.Error!Self {
            return .{
                .allocator = allocator,
                .values = try allocator.alloc(T, capacity_value),
            };
        }

        pub fn deinit(self: *Self) void {
            self.assertInvariants();
            self.allocator.free(self.values);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            self.assertInvariants();

            return self.count_value;
        }

        pub fn capacity(self: *const Self) usize {
            self.assertInvariants();

            return self.values.len;
        }

        pub fn empty(self: *const Self) bool {
            self.assertInvariants();

            return self.count_value == 0;
        }

        pub fn items(self: *Self) []T {
            self.assertInvariants();

            return self.values[0..self.count_value];
        }

        pub fn push(self: *Self, value: T) void {
            self.assertInvariants();
            std.debug.assert(self.count_value < self.values.len);
            self.values[self.count_value] = value;
            self.count_value += 1;
        }

        pub fn pop(self: *Self) T {
            std.debug.assert(!self.empty());

            return self.popOrNull().?;
        }

        pub fn popOrNull(self: *Self) ?T {
            self.assertInvariants();
            if (self.count_value == 0) {
                return null;
            }

            self.count_value -= 1;

            return self.values[self.count_value];
        }

        pub fn peek(self: *const Self) T {
            self.assertInvariants();
            std.debug.assert(self.count_value != 0);

            return self.values[self.count_value - 1];
        }

        pub fn reset(self: *Self) void {
            self.assertInvariants();
            self.count_value = 0;
        }

        pub fn storagePointer(self: *Self) [*]T {
            return self.values.ptr;
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.count_value <= self.values.len);
        }
    };
}

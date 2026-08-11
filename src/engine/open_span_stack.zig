const std = @import("std");

const interval = @import("shared").interval;
const stack = @import("shared").stack;

pub const OpenSpanStack = struct {
    pub const Interval = interval.Type(u32, .half_open);
    pub const Entry = struct {
        index: usize,
        range: Interval,
    };

    values: stack.ValueStackType(Entry),
    previous_start: ?u32 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Self {
        return .{ .values = try .init(allocator, capacity) };
    }

    pub fn deinit(self: *Self) void {
        self.values.deinit();
        self.* = undefined;
    }

    pub fn prepare(self: *Self, current: Interval) void {
        // Input must be sorted by start. In properly nested syntax ranges, any
        // open range that does not contain current has ended and cannot contain
        // a later range either.
        if (self.previous_start) |start| std.debug.assert(start <= current.start);
        self.previous_start = current.start;

        while (!self.values.empty() and !self.values.peek().range.containsInterval(current)) {
            std.debug.assert(self.values.peek().range.endsBefore(current));
            _ = self.values.pop();
        }

        if (!self.values.empty()) std.debug.assert(self.values.peek().range.containsInterval(current));
    }

    pub fn push(self: *Self, index: usize, range: Interval) void {
        if (!self.values.empty()) std.debug.assert(self.values.peek().range.containsInterval(range));
        self.values.push(.{ .index = index, .range = range });
    }

    pub fn items(self: *Self) []Entry {
        return self.values.items();
    }
};

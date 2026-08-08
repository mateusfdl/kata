const std = @import("std");

pub const Semantics = enum {
    closed,
    half_open,
};

pub fn Type(comptime T: type, comptime semantics: Semantics) type {
    return struct {
        start: T,
        end: T,

        const Self = @This();

        pub fn init(start: T, end: T) Self {
            std.debug.assert(start <= end);
            return .{ .start = start, .end = end };
        }

        pub fn contains(self: Self, point: T) bool {
            return switch (semantics) {
                .closed => self.start <= point and point <= self.end,
                .half_open => self.start <= point and point < self.end,
            };
        }

        pub fn containsInterval(self: Self, other: Self) bool {
            return self.start <= other.start and other.end <= self.end;
        }

        pub fn strictlyContains(self: Self, other: Self) bool {
            return self.containsInterval(other) and !self.eql(other);
        }

        pub fn endsBefore(self: Self, other: Self) bool {
            return switch (semantics) {
                .closed => self.end < other.start,
                .half_open => self.end <= other.start,
            };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.start == other.start and self.end == other.end;
        }
    };
}

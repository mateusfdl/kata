const std = @import("std");

const interval = @import("interval.zig");

const Closed = interval.Type(u32, .closed);
const HalfOpen = interval.Type(u32, .half_open);

test "closed interval contains both endpoints" {
    const value = Closed.init(2, 5);

    try std.testing.expectEqual(true, value.contains(2));
    try std.testing.expectEqual(true, value.contains(5));
    try std.testing.expectEqual(false, value.contains(6));
}

test "half-open interval excludes its end" {
    const value = HalfOpen.init(2, 5);

    try std.testing.expectEqual(true, value.contains(2));
    try std.testing.expectEqual(false, value.contains(5));
}

test "strict containment rejects only an identical interval" {
    const outer = HalfOpen.init(2, 8);

    try std.testing.expectEqual(true, outer.strictlyContains(HalfOpen.init(2, 5)));
    try std.testing.expectEqual(true, outer.strictlyContains(HalfOpen.init(4, 8)));
    try std.testing.expectEqual(false, outer.strictlyContains(outer));
    try std.testing.expectEqual(false, outer.strictlyContains(HalfOpen.init(1, 5)));
}

test "interval end ordering follows its boundary semantics" {
    try std.testing.expectEqual(false, Closed.init(0, 2).endsBefore(Closed.init(2, 4)));
    try std.testing.expectEqual(true, HalfOpen.init(0, 2).endsBefore(HalfOpen.init(2, 4)));
}

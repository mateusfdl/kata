const std = @import("std");

const OpenSpanStack = @import("open_span_stack.zig").OpenSpanStack;

test "open span stack keeps nested spans and removes completed spans" {
    var open_spans = try OpenSpanStack.init(std.testing.allocator, 3);
    defer open_spans.deinit();

    open_spans.prepare(.init(0, 10));
    open_spans.push(0, .init(0, 10));
    open_spans.prepare(.init(2, 4));
    open_spans.push(1, .init(2, 4));

    try std.testing.expectEqualSlices(
        OpenSpanStack.Entry,
        &.{
            .{ .index = 0, .range = .init(0, 10) },
            .{ .index = 1, .range = .init(2, 4) },
        },
        open_spans.items(),
    );

    open_spans.prepare(.init(6, 8));

    try std.testing.expectEqualSlices(
        OpenSpanStack.Entry,
        &.{.{ .index = 0, .range = .init(0, 10) }},
        open_spans.items(),
    );
}

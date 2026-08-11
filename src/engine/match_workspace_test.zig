const std = @import("std");

const MatchWorkspace = @import("match_workspace.zig").MatchWorkspace;
const Node = @import("node.zig").Node;

test "match workspace grows for larger capture counts" {
    var workspace = MatchWorkspace.init(std.testing.allocator);
    defer workspace.deinit();

    try workspace.reset(2);
    try std.testing.expectEqual(@as(usize, 2), workspace.active().len);
    try std.testing.expect(workspace.capacity() >= 2);

    try workspace.reset(5);
    try std.testing.expectEqual(@as(usize, 5), workspace.active().len);
    try std.testing.expect(workspace.capacity() >= 5);
}

test "match workspace reuses capacity for smaller capture counts" {
    var workspace = MatchWorkspace.init(std.testing.allocator);
    defer workspace.deinit();

    try workspace.reset(5);
    const storage = workspace.active().ptr;
    const capacity = workspace.capacity();

    try workspace.reset(2);
    try std.testing.expectEqual(storage, workspace.active().ptr);
    try std.testing.expectEqual(capacity, workspace.capacity());
    try std.testing.expectEqual(@as(usize, 2), workspace.active().len);
}

test "match workspace clears the active capture prefix" {
    var workspace = MatchWorkspace.init(std.testing.allocator);
    defer workspace.deinit();

    try workspace.reset(3);
    const marker: Node = .{ .tree = undefined, .index = 1 };
    @memset(workspace.active(), marker);

    try workspace.reset(2);
    try std.testing.expectEqualSlices(?Node, &.{ null, null }, workspace.active());
    try std.testing.expectEqual(@as(u32, 1), workspace.bindings[2].?.index);

    try workspace.reset(3);
    try std.testing.expectEqualSlices(?Node, &.{ null, null, null }, workspace.active());
}

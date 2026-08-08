const std = @import("std");

const staged_matcher = @import("staged_matcher.zig");

const Finding = struct {
    rule: []const u8,
    fingerprint: []const u8,
    span: []const u8,
};

fn sameFingerprint(_: void, _: usize, current: Finding, _: usize, candidate: Finding) bool {
    return current.fingerprint.len > 0 and std.mem.eql(u8, current.fingerprint, candidate.fingerprint);
}

fn sameSpan(_: void, _: usize, current: Finding, _: usize, candidate: Finding) bool {
    return std.mem.eql(u8, current.rule, candidate.rule) and std.mem.eql(u8, current.span, candidate.span);
}

test "staged matcher gives an earlier stage priority" {
    const current = [_]Finding{
        .{ .rule = "a", .fingerprint = "exact", .span = "new-a" },
        .{ .rule = "a", .fingerprint = "", .span = "same" },
    };
    const baseline = [_]Finding{
        .{ .rule = "a", .fingerprint = "exact", .span = "same" },
        .{ .rule = "a", .fingerprint = "other", .span = "same" },
    };
    var state = try staged_matcher.State.init(std.testing.allocator, current.len, baseline.len);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.applyStage(&current, &baseline, {}, sameFingerprint));
    try std.testing.expectEqual(@as(usize, 1), state.applyStage(&current, &baseline, {}, sameSpan));
    try std.testing.expectEqualSlices(bool, &.{ true, true }, state.matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, state.used);
}

test "staged matcher is ordered and one-to-one" {
    const current = [_]Finding{
        .{ .rule = "a", .fingerprint = "", .span = "same" },
        .{ .rule = "a", .fingerprint = "", .span = "same" },
        .{ .rule = "a", .fingerprint = "", .span = "same" },
    };
    const baseline = [_]Finding{
        .{ .rule = "a", .fingerprint = "", .span = "same" },
        .{ .rule = "a", .fingerprint = "", .span = "same" },
    };
    var state = try staged_matcher.State.init(std.testing.allocator, current.len, baseline.len);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 2), state.applyStage(&current, &baseline, {}, sameSpan));
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, state.matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, state.used);
}

const std = @import("std");

const baseline_matcher = @import("baseline_matcher.zig");

const StringContext = struct {
    pub fn hash(_: StringContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StringContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

const StringKeys = baseline_matcher.Keys([]const u8, StringContext);

test "baseline matcher gives the first current finding a competing exact key" {
    const current_fingerprints = [_]?[]const u8{ "exact", "exact" };
    const candidate_fingerprints = [_]?[]const u8{"exact"};
    const current_spans = [_]?[]const u8{ "current-first", "candidate-span" };
    const candidate_spans = [_]?[]const u8{"candidate-span"};
    const current_blocks = [_]?[]const u8{ null, null };
    const candidate_blocks = [_]?[]const u8{null};

    var state = try baseline_matcher.match(
        std.testing.allocator,
        StringKeys.init(&current_fingerprints, &candidate_fingerprints, .{}),
        StringKeys.init(&current_spans, &candidate_spans, .{}),
        StringKeys.init(&current_blocks, &candidate_blocks, .{}),
    );
    defer state.deinit();

    try std.testing.expectEqualSlices(bool, &.{ true, false }, state.matched);
    try std.testing.expectEqualSlices(bool, &.{true}, state.used);
}

test "baseline matcher calculates unique block groups after exact stages" {
    const current_fingerprints = [_]?[]const u8{ "exact", null };
    const candidate_fingerprints = [_]?[]const u8{ "exact", null };
    const current_spans = [_]?[]const u8{ "current-a", "current-b" };
    const candidate_spans = [_]?[]const u8{ "candidate-a", "candidate-b" };
    const current_blocks = [_]?[]const u8{ "block", "block" };
    const candidate_blocks = [_]?[]const u8{ "block", "block" };

    var state = try baseline_matcher.match(
        std.testing.allocator,
        StringKeys.init(&current_fingerprints, &candidate_fingerprints, .{}),
        StringKeys.init(&current_spans, &candidate_spans, .{}),
        StringKeys.init(&current_blocks, &candidate_blocks, .{}),
    );
    defer state.deinit();

    try std.testing.expectEqualSlices(bool, &.{ true, true }, state.matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, state.used);
}

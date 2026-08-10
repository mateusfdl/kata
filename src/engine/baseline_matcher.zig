const std = @import("std");

const group_index = @import("shared").group_index;
const staged_matcher = @import("shared").staged_matcher;

pub fn Keys(comptime Key: type, comptime Context: type) type {
    return struct {
        current: []const ?Key,
        candidates: []const ?Key,
        context: Context,

        const Self = @This();
        const Groups = group_index.Type(Key, usize, Context);

        pub fn init(
            current: []const ?Key,
            candidates: []const ?Key,
            context: Context,
        ) Self {
            return .{
                .current = current,
                .candidates = candidates,
                .context = context,
            };
        }

        fn candidateGroups(self: Self, arena: std.mem.Allocator) !Groups {
            return self.groups(arena, self.candidates, null);
        }

        fn remainingCurrentGroups(
            self: Self,
            arena: std.mem.Allocator,
            state: *const staged_matcher.State,
        ) !Groups {
            return self.groups(arena, self.current, state.matched);
        }

        fn remainingCandidateGroups(
            self: Self,
            arena: std.mem.Allocator,
            state: *const staged_matcher.State,
        ) !Groups {
            return self.groups(arena, self.candidates, state.used);
        }

        fn groups(
            self: Self,
            arena: std.mem.Allocator,
            keys: []const ?Key,
            excluded: ?[]const bool,
        ) !Groups {
            if (excluded) |items| std.debug.assert(items.len == keys.len);

            // Group values are original slice indexes. Exclusion filters matches
            // from stronger stages without renumbering the remaining items.
            var entries: std.ArrayList(Groups.Entry) = .empty;
            for (keys, 0..) |optional_key, index| {
                if (excluded) |items| {
                    if (items[index]) continue;
                }
                const key = optional_key orelse continue;
                try entries.append(arena, .{ .key = key, .value = index });
            }

            return Groups.build(arena, entries.items, self.context);
        }
    };
}

pub fn match(
    allocator: std.mem.Allocator,
    fingerprints: anytype,
    spans: anytype,
    blocks: anytype,
) !staged_matcher.State {
    std.debug.assert(fingerprints.current.len == spans.current.len);
    std.debug.assert(fingerprints.current.len == blocks.current.len);
    std.debug.assert(fingerprints.candidates.len == spans.candidates.len);
    std.debug.assert(fingerprints.candidates.len == blocks.candidates.len);

    var state = try staged_matcher.State.init(
        allocator,
        fingerprints.current.len,
        fingerprints.candidates.len,
    );
    errdefer state.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // Exact fingerprints survive source movement and are strongest. Normalized
    // rule spans are next. State consumption prevents a strong match from being
    // reused by a weaker stage.
    const fingerprint_groups = try fingerprints.candidateGroups(arena);
    _ = state.applyExactGroups(fingerprints.current, fingerprint_groups);

    const span_groups = try spans.candidateGroups(arena);
    _ = state.applyExactGroups(spans.current, span_groups);

    // A containing block is intentionally weak: repeated blocks can describe
    // unrelated findings. Use it only when the key is unique on both remaining
    // sides.
    const current_block_groups = try blocks.remainingCurrentGroups(arena, &state);
    const candidate_block_groups = try blocks.remainingCandidateGroups(arena, &state);
    _ = state.applyUniqueGroups(blocks.current, current_block_groups, candidate_block_groups);

    state.assertExactUse();
    return state;
}

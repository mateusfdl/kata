const std = @import("std");

pub const State = struct {
    // State persists across stages. A match removes both sides from every weaker
    // stage and makes the full operation one-to-one.
    matched: []bool,
    used: []bool,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        current_count: usize,
        candidate_count: usize,
    ) std.mem.Allocator.Error!State {
        const matched = try allocator.alloc(bool, current_count);
        errdefer allocator.free(matched);
        const used = try allocator.alloc(bool, candidate_count);

        @memset(matched, false);
        @memset(used, false);
        return .{ .matched = matched, .used = used, .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.matched);
        self.allocator.free(self.used);
        self.* = undefined;
    }

    pub fn applyStage(
        self: *State,
        current: anytype,
        candidates: anytype,
        context: anytype,
        comptime policy: anytype,
    ) usize {
        std.debug.assert(current.len == self.matched.len);
        std.debug.assert(candidates.len == self.used.len);

        var count: usize = 0;
        for (current, 0..) |item, current_index| {
            if (self.matched[current_index]) {
                continue;
            }
            for (candidates, 0..) |candidate, candidate_index| {
                if (self.used[candidate_index]) {
                    continue;
                }
                if (!policy(context, current_index, item, candidate_index, candidate)) {
                    continue;
                }

                self.matchAt(current_index, candidate_index);

                count += 1;
                break;
            }
        }

        self.assertExactUse();
        return count;
    }

    pub fn applyExactGroups(
        self: *State,
        current_keys: anytype,
        candidate_groups: anytype,
    ) usize {
        std.debug.assert(current_keys.len == self.matched.len);

        // Group values are stable candidate indexes. Select the first unused
        // index so duplicate keys retain deterministic candidate order.
        var count: usize = 0;
        for (current_keys, 0..) |optional_key, current_index| {
            if (self.matched[current_index]) continue;
            const key = optional_key orelse continue;
            for (candidate_groups.get(key)) |candidate_index| {
                std.debug.assert(candidate_index < self.used.len);
                if (self.used[candidate_index]) continue;
                self.matchAt(current_index, candidate_index);
                count += 1;
                break;
            }
        }

        self.assertExactUse();
        return count;
    }

    pub fn applyUniqueGroups(
        self: *State,
        current_keys: anytype,
        current_groups: anytype,
        candidate_groups: anytype,
    ) usize {
        std.debug.assert(current_keys.len == self.matched.len);

        var count: usize = 0;
        for (current_keys, 0..) |optional_key, current_index| {
            if (self.matched[current_index]) continue;
            const key = optional_key orelse continue;
            // A weak key is safe only when it identifies exactly one unmatched
            // item on each side. Ambiguous groups remain unmatched.
            const current_group = current_groups.get(key);
            if (current_group.len != 1) continue;
            std.debug.assert(current_group[0] == current_index);

            const candidate_group = candidate_groups.get(key);
            if (candidate_group.len != 1) continue;
            const candidate_index = candidate_group[0];
            std.debug.assert(candidate_index < self.used.len);
            std.debug.assert(!self.used[candidate_index]);
            self.matchAt(current_index, candidate_index);
            count += 1;
        }

        self.assertExactUse();
        return count;
    }

    pub fn matchAt(self: *State, current_index: usize, candidate_index: usize) void {
        std.debug.assert(current_index < self.matched.len);
        std.debug.assert(candidate_index < self.used.len);
        std.debug.assert(!self.matched[current_index]);
        std.debug.assert(!self.used[candidate_index]);
        self.matched[current_index] = true;
        self.used[candidate_index] = true;
    }

    pub fn assertExactUse(self: State) void {
        var matched_count: usize = 0;
        for (self.matched) |matched| matched_count += @intFromBool(matched);

        var used_count: usize = 0;
        for (self.used) |used| used_count += @intFromBool(used);

        std.debug.assert(matched_count == used_count);
    }
};

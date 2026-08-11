const std = @import("std");

const dense_multi_map = @import("shared").dense_multi_map;
const query = @import("query.zig");
const root_kind_set = @import("root_kind_set.zig");
const rule = @import("rule.zig");
const TableMemory = @import("shared").table_memory.TableMemory;

const DenseMultiMap = dense_multi_map.DenseMultiMapType(usize);

pub const Error = root_kind_set.Error || DenseMultiMap.BuildError;

pub const PatternIndex = struct {
    map: DenseMultiMap,

    pub const empty: PatternIndex = .{ .map = .empty };

    pub fn build(
        arena: std.mem.Allocator,
        allocator: std.mem.Allocator,
        patterns: []const query.Pattern,
        kind_count: u16,
    ) Error!PatternIndex {
        var memory = TableMemory.init(arena, allocator);
        defer memory.deinit();
        return buildWithMemory(&memory, patterns, kind_count);
    }

    pub fn buildWithMemory(
        memory: *TableMemory,
        patterns: []const query.Pattern,
        kind_count: u16,
    ) Error!PatternIndex {
        const scratch = memory.scratch();
        var entries: std.ArrayList(DenseMultiMap.Entry) = .empty;
        for (patterns, 0..) |*pattern, pattern_index| {
            std.debug.assert(pattern_index < patterns.len);
            const kinds = try root_kind_set.derive(scratch, pattern);
            for (kinds) |kind| {
                if (kind >= kind_count) return error.KeyOutOfRange;
                std.debug.assert(kind < kind_count);
                try entries.append(scratch, .{
                    .key = kind,
                    .value = pattern_index,
                });
            }
        }

        return .{ .map = try DenseMultiMap.build(memory, kind_count, entries.items) };
    }

    pub fn get(self: PatternIndex, kind: u16) []const usize {
        return self.map.get(kind);
    }
};

pub const Table = struct {
    map: DenseMultiMap,

    pub const empty: Table = .{ .map = .empty };

    pub fn build(
        arena: std.mem.Allocator,
        allocator: std.mem.Allocator,
        patterns: []const rule.CompiledPattern,
        kind_count: u16,
    ) Error!Table {
        var memory = TableMemory.init(arena, allocator);
        defer memory.deinit();
        return buildWithMemory(&memory, patterns, kind_count);
    }

    pub fn buildWithMemory(
        memory: *TableMemory,
        patterns: []const rule.CompiledPattern,
        kind_count: u16,
    ) Error!Table {
        const scratch = memory.scratch();
        const pattern_indexes = try scratch.alloc(usize, patterns.len);
        for (pattern_indexes, 0..) |*pattern_index, index| pattern_index.* = index;
        // Dense buckets preserve insertion order. Sort pattern indexes once so
        // each node dispatches by rule ID, independent of source configuration
        // order, while duplicate IDs retain compile order.
        std.sort.pdq(usize, pattern_indexes, patterns, patternBefore);

        var entries: std.ArrayList(DenseMultiMap.Entry) = .empty;
        for (pattern_indexes) |pattern_index| {
            std.debug.assert(pattern_index < patterns.len);
            const cp = patterns[pattern_index];
            const kinds = try root_kind_set.derive(scratch, &cp.pattern);
            for (kinds) |kind| {
                if (kind >= kind_count) return error.KeyOutOfRange;
                std.debug.assert(kind < kind_count);
                try entries.append(scratch, .{
                    .key = kind,
                    .value = pattern_index,
                });
            }
        }

        return .{ .map = try DenseMultiMap.build(memory, kind_count, entries.items) };
    }

    pub fn keyCount(self: Table) usize {
        return self.map.keyCount();
    }

    pub fn get(self: Table, kind: u16) []const usize {
        return self.map.get(kind);
    }
};

fn patternBefore(patterns: []const rule.CompiledPattern, a: usize, b: usize) bool {
    std.debug.assert(a < patterns.len);
    std.debug.assert(b < patterns.len);
    return switch (std.mem.order(u8, patterns[a].meta.rule_id, patterns[b].meta.rule_id)) {
        .lt => true,
        .gt => false,
        .eq => a < b,
    };
}

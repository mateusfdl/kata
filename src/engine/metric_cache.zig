const std = @import("std");

const metric = @import("metric.zig");
const Node = @import("node.zig").Node;

pub const MetricCache = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    analysis_count: usize = 0,

    const Validity = packed struct(u8) {
        complexity: bool = false,
        nesting: bool = false,
        padding: u6 = 0,
    };

    // Node indexes are dense and stable for a parsed tree, so a slice avoids a
    // hash lookup for each predicate evaluation.
    const Entry = struct {
        measures: metric.Measures = undefined,
        valid: Validity = .{},
    };

    pub fn init(allocator: std.mem.Allocator, root: Node) std.mem.Allocator.Error!MetricCache {
        const entries = try allocator.alloc(Entry, root.tree.nodes.len);
        for (entries) |*entry| entry.* = .{};

        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *MetricCache) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn complexity(
        self: *MetricCache,
        analysis_allocator: std.mem.Allocator,
        compiled: *const metric.Compiled,
        node: Node,
    ) std.mem.Allocator.Error!u32 {
        const entry = &self.entries[node.index];
        if (!entry.valid.complexity) try self.fill(analysis_allocator, compiled, node, entry);

        return entry.measures.complexity;
    }

    pub fn nesting(
        self: *MetricCache,
        analysis_allocator: std.mem.Allocator,
        compiled: *const metric.Compiled,
        node: Node,
    ) std.mem.Allocator.Error!u32 {
        const entry = &self.entries[node.index];
        if (!entry.valid.nesting) try self.fill(analysis_allocator, compiled, node, entry);

        return entry.measures.nesting;
    }

    pub fn analysisCount(self: *const MetricCache) usize {
        return self.analysis_count;
    }

    fn fill(
        self: *MetricCache,
        analysis_allocator: std.mem.Allocator,
        compiled: *const metric.Compiled,
        node: Node,
        entry: *Entry,
    ) std.mem.Allocator.Error!void {
        var analysis = try metric.analyze(analysis_allocator, compiled, node);
        defer analysis.deinit();

        // Metric analysis computes complexity and nesting in one traversal.
        // Publish both validity bits only after measures succeeds.
        entry.measures = try analysis.measures();
        entry.valid = .{ .complexity = true, .nesting = true };
        self.analysis_count += 1;
    }
};

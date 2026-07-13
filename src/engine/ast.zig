const std = @import("std");

const family_mod = @import("family/family.zig");

pub const NodeIndex = u32;

/// Parent link of the root: no node reports this index.
pub const no_parent: NodeIndex = std.math.maxInt(NodeIndex);

pub const Point = struct {
    row: u32,
    column: u32,
};

pub const Flags = packed struct(u8) {
    named: bool,
    extra: bool,
    _pad: u6 = 0,
};

/// One node in the flat pre-order (DFS) store. A node's descendants are exactly
/// the contiguous range `[index + 1, subtree_end)`, so direct children need no
/// child-list: walk them by `j = index + 1; j = nodes[j].subtree_end`. Kinds and
/// fields are kata ids, applied at convert time, so the store is self-describing.
pub const StoredNode = struct {
    kind: u16,
    field_id: u16,
    flags: Flags,
    start_byte: u32,
    end_byte: u32,
    subtree_end: NodeIndex,
    parent: NodeIndex,
};

/// kata's own syntax tree: a flat clone of a parsed CST that outlives the
/// tree-sitter tree it was built from. Points are not stored per node; they are
/// derived on demand from byte offsets against `line_starts`.
pub const Ast = struct {
    family: family_mod.Family,
    nodes: []const StoredNode,
    line_starts: []const u32,

    pub fn deinit(self: *Ast, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.line_starts);
    }

    pub fn root(self: Ast) NodeIndex {
        _ = self;
        return 0;
    }

    pub fn pointAt(self: Ast, byte: u32) Point {
        const row = self.rowForByte(byte);
        return .{ .row = row, .column = byte - self.line_starts[row] };
    }

    /// Greatest row whose line start is at or before `byte`. tree-sitter counts
    /// columns in bytes, so `byte - line_starts[row]` reproduces its column.
    fn rowForByte(self: Ast, byte: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= byte) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo - 1);
    }
};

const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const edit_planner = @import("shared").edit_planner;
const line_index = @import("line_index.zig");

pub const Edit = edit_planner.Edit;
pub const Plan = edit_planner.Plan;
pub const PlannedEdit = edit_planner.PlannedEdit;
pub const RejectedEdit = edit_planner.RejectedEdit;
pub const RejectionReason = edit_planner.RejectionReason;
pub const plan = edit_planner.plan;

pub fn fromFixes(
    arena: std.mem.Allocator,
    source: []const u8,
    fixes: []const diagnostic.Fix,
) ![]Edit {
    var index = try line_index.LineIndex.init(arena, source);
    defer index.deinit(arena);

    const out = try arena.alloc(Edit, fixes.len);
    for (fixes, out) |fix, *edit| {
        const range = index.byteRange(source.len, fix.range);
        edit.* = .{ .start = range.start, .end = range.end, .text = fix.replacement };
    }

    return out;
}

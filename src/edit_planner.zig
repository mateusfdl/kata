const std = @import("std");

pub const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

pub const PlannedEdit = struct {
    edit: Edit,
    priority: usize,
};

pub const RejectionReason = enum {
    duplicate,
    conflict,
};

pub const RejectedEdit = struct {
    edit: Edit,
    priority: usize,
    reason: RejectionReason,
};

pub const Plan = struct {
    accepted: []const PlannedEdit,
    rejected: []const RejectedEdit,

    pub fn apply(self: Plan, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        // accepted is ordered and non-overlapping, so one forward pass can copy
        // unchanged spans and replacements without adjusting later offsets.
        var output_len = source.len;
        for (self.accepted) |planned| {
            const edit = planned.edit;
            if (edit.start > edit.end or edit.end > source.len) return error.InvalidEditRange;
            output_len = try std.math.sub(usize, output_len, edit.end - edit.start);
            output_len = try std.math.add(usize, output_len, edit.text.len);
        }

        const output = try allocator.alloc(u8, output_len);
        var source_cursor: usize = 0;
        var output_cursor: usize = 0;
        for (self.accepted) |planned| {
            const edit = planned.edit;
            const unchanged = source[source_cursor..edit.start];
            @memcpy(output[output_cursor..][0..unchanged.len], unchanged);
            output_cursor += unchanged.len;
            @memcpy(output[output_cursor..][0..edit.text.len], edit.text);
            output_cursor += edit.text.len;
            source_cursor = edit.end;
        }

        const remaining = source[source_cursor..];
        @memcpy(output[output_cursor..][0..remaining.len], remaining);
        return output;
    }
};

pub fn plan(allocator: std.mem.Allocator, list: []const Edit) !Plan {
    // Sort by source range, then preserve input order as the final tie-breaker.
    // For one start offset, this gives the shortest range priority; for an
    // identical range, the first producer wins.
    const ordered = try allocator.alloc(PlannedEdit, list.len);
    for (list, 0..) |edit, priority| {
        ordered[priority] = .{ .edit = edit, .priority = priority };
    }
    std.sort.pdq(PlannedEdit, ordered, {}, lessThan);

    const accepted = try allocator.alloc(PlannedEdit, list.len);
    const rejected = try allocator.alloc(RejectedEdit, list.len);
    var accepted_len: usize = 0;
    var rejected_len: usize = 0;

    for (ordered) |candidate| {
        if (accepted_len == 0) {
            accepted[accepted_len] = candidate;
            accepted_len += 1;
            continue;
        }

        // Accepted edits are sorted and non-overlapping. Only the last accepted
        // range can overlap this candidate.
        const previous = accepted[accepted_len - 1];
        const overlaps = candidate.edit.start < previous.edit.end;
        const same_start = candidate.edit.start == previous.edit.start;
        if (!overlaps and !same_start) {
            accepted[accepted_len] = candidate;
            accepted_len += 1;
            continue;
        }

        rejected[rejected_len] = .{
            .edit = candidate.edit,
            .priority = candidate.priority,
            .reason = if (equal(candidate.edit, previous.edit)) .duplicate else .conflict,
        };
        rejected_len += 1;
    }

    return .{
        .accepted = accepted[0..accepted_len],
        .rejected = rejected[0..rejected_len],
    };
}

fn lessThan(context: void, a: PlannedEdit, b: PlannedEdit) bool {
    _ = context;
    if (a.edit.start != b.edit.start) return a.edit.start < b.edit.start;
    if (a.edit.end != b.edit.end) return a.edit.end < b.edit.end;
    return a.priority < b.priority;
}

fn equal(a: Edit, b: Edit) bool {
    return a.start == b.start and
        a.end == b.end and
        std.mem.eql(u8, a.text, b.text);
}

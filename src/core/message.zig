const std = @import("std");

const expr = @import("expr.zig");
const query = @import("query.zig");

pub const Placeholder = struct {
    measure: expr.Measure,
    capture_id: query.CaptureId,
};

pub const Segment = union(enum) {
    literal: []const u8,
    placeholder: Placeholder,
};

pub const Message = union(enum) {
    plain: []const u8,
    segments: []const Segment,
};

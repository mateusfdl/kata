const std = @import("std");
const ts = @import("tree_sitter");

const expr = @import("expr.zig");

pub const invalid_capture_id: u32 = std.math.maxInt(u32);

pub const Placeholder = struct {
    measure: expr.Measure,
    capture_id: u32,
};

pub const Segment = union(enum) {
    literal: []const u8,
    placeholder: Placeholder,
};

pub const Message = union(enum) {
    plain: []const u8,
    segments: []const Segment,
};

pub const CompileError = error{
    UnclosedPlaceholder,
    StrayBraceInMessage,
    MalformedPlaceholder,
    UnknownPlaceholderMeasure,
    UnknownPlaceholderCapture,
} || std.mem.Allocator.Error;

pub fn compile(
    arena: std.mem.Allocator,
    query: *ts.Query,
    source: []const u8,
) CompileError!Message {
    const segments = (try compileSegments(arena, query, source)) orelse
        return .{ .plain = source };
    if (segments.len == 1 and segments[0] == .literal) return .{ .plain = segments[0].literal };
    return .{ .segments = segments };
}

fn compileSegments(
    arena: std.mem.Allocator,
    query: *ts.Query,
    source: []const u8,
) CompileError!?[]const Segment {
    if (std.mem.indexOfAny(u8, source, "{}") == null) return null;

    var segments: std.ArrayList(Segment) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '{') {
            if (i + 1 < source.len and source[i + 1] == '{') {
                try literal.append(arena, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, source, i + 1, '}') orelse
                return error.UnclosedPlaceholder;
            if (literal.items.len > 0)
                try segments.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });
            try segments.append(arena, .{ .placeholder = try parsePlaceholder(query, source[i + 1 .. close]) });
            i = close + 1;
            continue;
        }
        if (c == '}') {
            if (i + 1 < source.len and source[i + 1] == '}') {
                try literal.append(arena, '}');
                i += 2;
                continue;
            }
            return error.StrayBraceInMessage;
        }
        try literal.append(arena, c);
        i += 1;
    }
    if (literal.items.len > 0)
        try segments.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });
    return try segments.toOwnedSlice(arena);
}

fn parsePlaceholder(query: *ts.Query, inner: []const u8) CompileError!Placeholder {
    var it = std.mem.tokenizeScalar(u8, inner, ' ');
    const measure_name = it.next() orelse return error.MalformedPlaceholder;
    const capture = it.next() orelse return error.MalformedPlaceholder;
    if (it.next() != null) return error.MalformedPlaceholder;

    const measure = expr.Measure.fromString(measure_name) orelse return error.UnknownPlaceholderMeasure;
    if (capture.len < 2 or capture[0] != '@') return error.MalformedPlaceholder;
    const id = captureIdForName(query, capture[1..]);
    if (id == invalid_capture_id) return error.UnknownPlaceholderCapture;
    return .{ .measure = measure, .capture_id = id };
}

pub fn captureIdForName(query: *ts.Query, name: []const u8) u32 {
    const count = query.captureCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return invalid_capture_id;
}

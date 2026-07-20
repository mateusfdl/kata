const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fingerprint = @import("fingerprint.zig");

pub const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

pub const Applied = struct {
    source: []u8,
    applied: usize,
};

pub fn fromFixes(
    arena: std.mem.Allocator,
    source: []const u8,
    fixes: []const diagnostic.Fix,
) ![]Edit {
    const ranges = try arena.alloc(diagnostic.Range, fixes.len);
    for (fixes, ranges) |fix, *range| range.* = fix.range;

    const spans = try fingerprint.byteSpans(arena, source, ranges);
    const out = try arena.alloc(Edit, fixes.len);
    for (fixes, spans, out) |fix, span, *edit| {
        edit.* = .{ .start = span.start, .end = span.end, .text = fix.replacement };
    }

    return out;
}

pub fn apply(arena: std.mem.Allocator, source: []const u8, list: []Edit) !Applied {
    std.sort.pdq(Edit, list, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    var applied: usize = 0;
    var last_start: ?usize = null;
    for (list) |edit| {
        if (edit.start < cursor) continue;
        if (last_start == edit.start) continue;

        try out.appendSlice(arena, source[cursor..edit.start]);
        try out.appendSlice(arena, edit.text);

        cursor = edit.end;
        last_start = edit.start;
        applied += 1;
    }

    try out.appendSlice(arena, source[cursor..]);

    return .{ .source = try out.toOwnedSlice(arena), .applied = applied };
}

fn lessThan(context: void, a: Edit, b: Edit) bool {
    _ = context;
    if (a.start != b.start) return a.start < b.start;

    return a.end < b.end;
}

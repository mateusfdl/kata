const std = @import("std");

const diagnostic = @import("diagnostic.zig");

pub fn normalize(allocator: std.mem.Allocator, span: []const u8) ![]const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var pending_space = false;
    for (span) |byte| {
        if (isWhitespace(byte)) {
            if (normalized.items.len > 0) pending_space = true;
            continue;
        }

        if (pending_space) {
            try normalized.append(allocator, ' ');
            pending_space = false;
        }
        try normalized.append(allocator, byte);
    }

    return normalized.toOwnedSlice(allocator);
}

pub fn normalizedSpans(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![][]const u8 {
    const bounds = try spanBounds(arena, source, diagnostics);
    const spans = try arena.alloc([]const u8, diagnostics.len);
    for (bounds, spans) |b, *span| span.* = try normalize(arena, source[b.start..b.end]);

    return spans;
}

pub fn assign(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    diagnostics: []diagnostic.Diagnostic,
) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const bounds = try spanBounds(arena, source, diagnostics);
    const spans = try normalizeBounds(arena, source, bounds);

    const Finding = struct {
        rule_id: []const u8,
        normalized_span: []const u8,
        start: usize,
        end: usize,
        index: usize,
        occurrence_index: usize = 0,
    };

    const findings = try arena.alloc(Finding, diagnostics.len);
    for (diagnostics, 0..) |d, index| {
        findings[index] = .{
            .rule_id = d.rule_id,
            .normalized_span = spans[index],
            .start = bounds[index].start,
            .end = bounds[index].end,
            .index = index,
        };
    }

    std.mem.sort(Finding, findings, {}, struct {
        fn lessThan(_: void, a: Finding, b: Finding) bool {
            const rule_order = std.mem.order(u8, a.rule_id, b.rule_id);
            if (rule_order != .eq) return rule_order == .lt;
            const span_order = std.mem.order(u8, a.normalized_span, b.normalized_span);
            if (span_order != .eq) return span_order == .lt;
            return comesBefore(a, b);
        }
    }.lessThan);

    var occurrence_index: usize = 0;
    for (findings, 0..) |*finding, index| {
        if (index == 0 or !sameGroup(findings[index - 1], finding.*)) occurrence_index = 0 else occurrence_index += 1;
        finding.occurrence_index = occurrence_index;
    }

    for (findings) |finding| {
        const d = &diagnostics[finding.index];

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(finding.rule_id);
        hasher.update("\x00");
        hasher.update(path);
        hasher.update("\x00");
        hasher.update(finding.normalized_span);
        hasher.update("\x00");
        var occurrence_buffer: [20]u8 = undefined;
        const occurrence = try std.fmt.bufPrint(&occurrence_buffer, "{d}", .{finding.occurrence_index});
        hasher.update(occurrence);
        hasher.final(&digest);

        const hex = std.fmt.bytesToHex(digest, .lower);
        d.fingerprint = try allocator.dupe(u8, &hex);
    }
}

pub const Span = struct {
    start: usize,
    end: usize,
};

pub fn byteSpans(
    arena: std.mem.Allocator,
    source: []const u8,
    ranges: []const diagnostic.Range,
) ![]const Span {
    var line_offsets: std.ArrayList(usize) = .empty;
    try line_offsets.append(arena, 0);
    for (source, 0..) |byte, index| {
        if (byte == '\n') try line_offsets.append(arena, index + 1);
    }

    const bounds = try arena.alloc(Span, ranges.len);
    for (ranges, bounds) |range, *b| {
        const start = byteOffset(source.len, line_offsets.items, range.start);
        var end = byteOffset(source.len, line_offsets.items, range.end);
        if (end < start) end = start;
        b.* = .{ .start = start, .end = end };
    }

    return bounds;
}

fn spanBounds(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const Span {
    const ranges = try arena.alloc(diagnostic.Range, diagnostics.len);
    for (diagnostics, ranges) |d, *range| range.* = d.range;

    return byteSpans(arena, source, ranges);
}

fn normalizeBounds(
    arena: std.mem.Allocator,
    source: []const u8,
    bounds: []const Span,
) ![][]const u8 {
    const spans = try arena.alloc([]const u8, bounds.len);
    for (bounds, spans) |bound, *span| span.* = try normalize(arena, source[bound.start..bound.end]);
    return spans;
}

fn byteOffset(source_len: usize, line_offsets: []const usize, position: diagnostic.Position) usize {
    if (position.line >= line_offsets.len) return source_len;

    return @min(line_offsets[position.line] + position.column, source_len);
}

fn comesBefore(a: anytype, b: @TypeOf(a)) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    return a.index < b.index;
}

fn sameGroup(a: anytype, b: @TypeOf(a)) bool {
    return std.mem.eql(u8, a.rule_id, b.rule_id) and std.mem.eql(u8, a.normalized_span, b.normalized_span);
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

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
    const spans = try normalizedSpans(arena, source, diagnostics);

    const Finding = struct {
        rule_id: []const u8,
        normalized_span: []const u8,
        start: usize,
        end: usize,
        index: usize,
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

    for (findings, diagnostics) |finding, *d| {
        var occurrence_index: usize = 0;
        for (findings) |candidate| {
            if (!std.mem.eql(u8, candidate.rule_id, finding.rule_id)) continue;
            if (!std.mem.eql(u8, candidate.normalized_span, finding.normalized_span)) continue;
            if (comesBefore(candidate, finding)) occurrence_index += 1;
        }

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(finding.rule_id);
        hasher.update("\x00");
        hasher.update(path);
        hasher.update("\x00");
        hasher.update(finding.normalized_span);
        hasher.update("\x00");
        var occurrence_buffer: [20]u8 = undefined;
        const occurrence = try std.fmt.bufPrint(&occurrence_buffer, "{d}", .{occurrence_index});
        hasher.update(occurrence);
        hasher.final(&digest);

        const hex = std.fmt.bytesToHex(digest, .lower);
        d.fingerprint = try allocator.dupe(u8, &hex);
    }
}

const Span = struct {
    start: usize,
    end: usize,
};

fn spanBounds(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const Span {
    var line_offsets: std.ArrayList(usize) = .empty;
    try line_offsets.append(arena, 0);
    for (source, 0..) |byte, index| {
        if (byte == '\n') try line_offsets.append(arena, index + 1);
    }

    const bounds = try arena.alloc(Span, diagnostics.len);
    for (diagnostics, bounds) |d, *b| {
        const start = byteOffset(source.len, line_offsets.items, d.range.start);
        var end = byteOffset(source.len, line_offsets.items, d.range.end);
        if (end < start) end = start;
        b.* = .{ .start = start, .end = end };
    }

    return bounds;
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

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

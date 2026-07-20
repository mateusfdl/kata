const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fingerprint = @import("fingerprint.zig");

const BlockHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn demote(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []diagnostic.Diagnostic,
    baseline_source: []const u8,
    baseline: []const diagnostic.Diagnostic,
) !usize {
    const current_spans = try fingerprint.normalizedSpans(arena, source, diagnostics);
    const baseline_spans = try fingerprint.normalizedSpans(arena, baseline_source, baseline);
    const current_blocks = try blockHashes(arena, source, diagnostics);
    const baseline_blocks = try blockHashes(arena, baseline_source, baseline);

    const matched = try arena.alloc(bool, diagnostics.len);
    @memset(matched, false);
    const used = try arena.alloc(bool, baseline.len);
    @memset(used, false);

    matchFingerprints(diagnostics, baseline, matched, used);
    matchSpans(diagnostics, current_spans, baseline, baseline_spans, matched, used);
    matchBlocks(diagnostics, current_blocks, baseline, baseline_blocks, matched, used);

    var count: usize = 0;
    for (diagnostics, matched) |*d, hit| {
        if (!hit) continue;
        d.severity = .warn;
        d.demoted = true;
        count += 1;
    }

    return count;
}

fn matchFingerprints(
    diagnostics: []const diagnostic.Diagnostic,
    baseline: []const diagnostic.Diagnostic,
    matched: []bool,
    used: []bool,
) void {
    for (diagnostics, 0..) |d, i| {
        if (matched[i] or d.severity != .@"error") continue;
        if (d.fingerprint.len == 0) continue;
        for (baseline, 0..) |b, j| {
            if (used[j]) continue;
            if (!std.mem.eql(u8, d.fingerprint, b.fingerprint)) continue;
            matched[i] = true;
            used[j] = true;
            break;
        }
    }
}

fn matchSpans(
    diagnostics: []const diagnostic.Diagnostic,
    current_spans: []const []const u8,
    baseline: []const diagnostic.Diagnostic,
    baseline_spans: []const []const u8,
    matched: []bool,
    used: []bool,
) void {
    for (diagnostics, current_spans, 0..) |d, span, i| {
        if (matched[i] or d.severity != .@"error") continue;
        for (baseline, baseline_spans, 0..) |b, before_span, j| {
            if (used[j]) continue;
            if (!std.mem.eql(u8, d.rule_id, b.rule_id)) continue;
            if (!std.mem.eql(u8, span, before_span)) continue;
            matched[i] = true;
            used[j] = true;
            break;
        }
    }
}

fn matchBlocks(
    diagnostics: []const diagnostic.Diagnostic,
    current_blocks: []const ?BlockHash,
    baseline: []const diagnostic.Diagnostic,
    baseline_blocks: []const ?BlockHash,
    matched: []bool,
    used: []bool,
) void {
    for (diagnostics, 0..) |d, i| {
        if (matched[i] or d.severity != .@"error") continue;
        const block = current_blocks[i] orelse continue;

        var current_count: usize = 0;
        for (diagnostics, 0..) |other, k| {
            if (matched[k] or other.severity != .@"error") continue;
            const other_block = current_blocks[k] orelse continue;
            if (!std.mem.eql(u8, other.rule_id, d.rule_id)) continue;
            if (std.mem.eql(u8, &other_block, &block)) current_count += 1;
        }
        if (current_count != 1) continue;

        var baseline_count: usize = 0;
        var baseline_index: usize = 0;
        for (baseline, 0..) |b, j| {
            if (used[j]) continue;
            const before_block = baseline_blocks[j] orelse continue;
            if (!std.mem.eql(u8, b.rule_id, d.rule_id)) continue;
            if (!std.mem.eql(u8, &before_block, &block)) continue;
            baseline_count += 1;
            baseline_index = j;
        }
        if (baseline_count != 1) continue;

        matched[i] = true;
        used[baseline_index] = true;
    }
}

fn blockHashes(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const ?BlockHash {
    const blocks = try arena.alloc(diagnostic.Diagnostic, diagnostics.len);
    for (diagnostics, blocks) |d, *block| {
        block.* = d;
        if (d.context.len > 0) block.range = d.context[d.context.len - 1].range;
    }

    const spans = try fingerprint.normalizedSpans(arena, source, blocks);
    const hashes = try arena.alloc(?BlockHash, diagnostics.len);
    for (diagnostics, spans, hashes) |d, span, *hash| {
        if (d.context.len == 0) {
            hash.* = null;
            continue;
        }

        var digest: BlockHash = undefined;
        std.crypto.hash.sha2.Sha256.hash(span, &digest, .{});
        hash.* = digest;
    }

    return hashes;
}

const std = @import("std");

const baseline_matcher = @import("baseline_matcher.zig");
const diagnostic = @import("diagnostic.zig");
const fingerprint = @import("fingerprint.zig");

const BlockHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const StringContext = struct {
    pub fn hash(_: StringContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: StringContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

const SpanKey = struct {
    rule_id: []const u8,
    span: []const u8,
};

const SpanContext = struct {
    pub fn hash(_: SpanContext, key: SpanKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.rule_id);
        hasher.update(key.span);
        return hasher.final();
    }

    pub fn eql(_: SpanContext, a: SpanKey, b: SpanKey) bool {
        return std.mem.eql(u8, a.rule_id, b.rule_id) and std.mem.eql(u8, a.span, b.span);
    }
};

const BlockKey = struct {
    rule_id: []const u8,
    block: BlockHash,
};

const BlockContext = struct {
    pub fn hash(_: BlockContext, key: BlockKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.rule_id);
        hasher.update(&key.block);
        return hasher.final();
    }

    pub fn eql(_: BlockContext, a: BlockKey, b: BlockKey) bool {
        return std.mem.eql(u8, a.rule_id, b.rule_id) and std.mem.eql(u8, &a.block, &b.block);
    }
};

const FingerprintKeys = baseline_matcher.Keys([]const u8, StringContext);
const SpanKeys = baseline_matcher.Keys(SpanKey, SpanContext);
const BlockKeys = baseline_matcher.Keys(BlockKey, BlockContext);

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

    std.debug.assert(current_spans.len == diagnostics.len);
    std.debug.assert(current_blocks.len == diagnostics.len);
    std.debug.assert(baseline_spans.len == baseline.len);
    std.debug.assert(baseline_blocks.len == baseline.len);

    const current_fingerprints = try fingerprintKeys(arena, diagnostics, true);
    const baseline_fingerprints = try fingerprintKeys(arena, baseline, false);
    const current_span_keys = try spanKeys(arena, diagnostics, current_spans, true);
    const baseline_span_keys = try spanKeys(arena, baseline, baseline_spans, false);
    const current_block_keys = try blockKeys(arena, diagnostics, current_blocks, true);
    const baseline_block_keys = try blockKeys(arena, baseline, baseline_blocks, false);

    // Matching mutates only current enforcing errors. Baseline warnings remain
    // candidates because they still prove that a finding existed at the ref.
    var state = try baseline_matcher.match(
        arena,
        FingerprintKeys.init(current_fingerprints, baseline_fingerprints, .{}),
        SpanKeys.init(current_span_keys, baseline_span_keys, .{}),
        BlockKeys.init(current_block_keys, baseline_block_keys, .{}),
    );
    defer state.deinit();

    var count: usize = 0;
    for (diagnostics, state.matched) |*d, hit| {
        if (!hit) continue;
        d.severity = .warn;
        d.demoted = true;
        count += 1;
    }

    return count;
}

fn fingerprintKeys(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
    errors_only: bool,
) ![]const ?[]const u8 {
    const keys = try arena.alloc(?[]const u8, diagnostics.len);
    for (diagnostics, keys) |d, *key| {
        key.* = null;
        if (errors_only and d.severity != .@"error") continue;
        if (d.fingerprint.len > 0) key.* = d.fingerprint;
    }

    return keys;
}

fn spanKeys(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
    spans: []const []const u8,
    errors_only: bool,
) ![]const ?SpanKey {
    std.debug.assert(diagnostics.len == spans.len);

    const keys = try arena.alloc(?SpanKey, diagnostics.len);
    for (diagnostics, spans, keys) |d, span, *key| {
        key.* = null;
        if (errors_only and d.severity != .@"error") continue;
        key.* = .{ .rule_id = d.rule_id, .span = span };
    }

    return keys;
}

fn blockKeys(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
    blocks: []const ?BlockHash,
    errors_only: bool,
) ![]const ?BlockKey {
    std.debug.assert(diagnostics.len == blocks.len);

    const keys = try arena.alloc(?BlockKey, diagnostics.len);
    for (diagnostics, blocks, keys) |d, optional_block, *key| {
        key.* = null;
        if (errors_only and d.severity != .@"error") continue;
        const block = optional_block orelse continue;
        key.* = .{ .rule_id = d.rule_id, .block = block };
    }

    return keys;
}

fn blockHashes(
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const ?BlockHash {
    // Reuse normalized-span logic with the outermost diagnostic context range.
    // Hashes avoid retaining large normalized block slices in matching keys.
    const blocks = try arena.alloc(diagnostic.Diagnostic, diagnostics.len);
    for (diagnostics, blocks) |d, *block| {
        block.* = d;
        if (d.context.len > 0) block.range = d.context[d.context.len - 1].range;
    }

    const spans = try fingerprint.normalizedSpans(arena, source, blocks);
    const hashes = try arena.alloc(?BlockHash, diagnostics.len);
    std.debug.assert(spans.len == diagnostics.len);
    std.debug.assert(hashes.len == diagnostics.len);
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

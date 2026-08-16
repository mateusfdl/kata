const std = @import("std");

const replay = @import("replay.zig");

const diagnostic = @import("engine").diagnostic;
const language = @import("engine").language;

const capacity: usize = 2048;
const path_count: usize = capacity * 3;
const sample_count: usize = 6;
const hot_operations: usize = 500_000;
const insertion_operations: usize = capacity;
const mixed_operations: usize = 32_768;
const warmup_operations: usize = 4096;
const Path = [32]u8;
const ContentHash = [32]u8;

const Data = struct {
    paths: []Path,
    hashes: []ContentHash,
    stale_hashes: []ContentHash,
    natural_paths: []Path,
    natural_hashes: []ContentHash,
    natural_stale_hashes: []ContentHash,
    trace: []TraceOperation,

    fn init(gpa: std.mem.Allocator) !Data {
        const paths = try gpa.alloc(Path, path_count);
        errdefer gpa.free(paths);
        const hashes = try gpa.alloc(ContentHash, path_count);
        errdefer gpa.free(hashes);
        const stale_hashes = try gpa.alloc(ContentHash, path_count);
        errdefer gpa.free(stale_hashes);
        const natural_paths = try gpa.alloc(Path, path_count);
        errdefer gpa.free(natural_paths);
        const natural_hashes = try gpa.alloc(ContentHash, path_count);
        errdefer gpa.free(natural_hashes);
        const natural_stale_hashes = try gpa.alloc(ContentHash, path_count);
        errdefer gpa.free(natural_stale_hashes);
        const trace = try gpa.alloc(TraceOperation, mixed_operations);
        errdefer gpa.free(trace);

        for (0..path_count) |index| {
            fillPath(&paths[index], index);
            fillHash(&hashes[index], &paths[index]);
            stale_hashes[index] = hashes[index];
            stale_hashes[index][0] ^= 0xff;
        }

        for (0..path_count) |index| {
            fillPath(&natural_paths[index], index);
            fillHash(&natural_hashes[index], &natural_paths[index]);
            natural_stale_hashes[index] = natural_hashes[index];
            natural_stale_hashes[index][0] ^= 0xff;
        }

        var next_insert = capacity;
        var last_insert = capacity;
        for (trace, 0..) |*operation, index| {
            const phase = index % 100;
            if (phase < 55) {
                operation.* = .{ .kind = .get, .path_index = (index * 17) % 64 };
            } else if (phase < 70) {
                operation.* = .{ .kind = .get, .path_index = (index * 73) % capacity };
            } else if (phase < 80) {
                operation.* = .{ .kind = .get_stale, .path_index = (index * 29) % 64 };
            } else if (phase < 90) {
                operation.* = .{ .kind = .get, .path_index = last_insert };
            } else {
                operation.* = .{ .kind = .put, .path_index = next_insert };
                last_insert = next_insert;
                next_insert += 1;
            }
        }

        return .{
            .paths = paths,
            .hashes = hashes,
            .stale_hashes = stale_hashes,
            .natural_paths = natural_paths,
            .natural_hashes = natural_hashes,
            .natural_stale_hashes = natural_stale_hashes,
            .trace = trace,
        };
    }

    fn deinit(self: Data, gpa: std.mem.Allocator) void {
        gpa.free(self.paths);
        gpa.free(self.hashes);
        gpa.free(self.stale_hashes);
        gpa.free(self.natural_paths);
        gpa.free(self.natural_hashes);
        gpa.free(self.natural_stale_hashes);
        gpa.free(self.trace);
    }
};

const TraceOperation = struct {
    kind: enum { get, get_stale, put },
    path_index: usize,
};

const Measurement = struct {
    elapsed_ns: u64,
    operations: u64,
    hits: u64,
    misses: u64,
    checksum: u64,
};

const MeasurementPair = struct {
    current: Measurement,
    prior: Measurement,
};

const FreshWorkload = enum {
    insertion,
    mixed,
    retention,
};

const OldReplayCache = struct {
    gpa: std.mem.Allocator,
    capacity: usize,
    clock: u64 = 0,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        arena: *std.heap.ArenaAllocator,
        content_hash: [32]u8,
        diagnostics: []const diagnostic.Diagnostic,
        last_used: u64,

        fn deinit(self: Entry, gpa: std.mem.Allocator) void {
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };

    fn init(gpa: std.mem.Allocator, cache_capacity: usize) OldReplayCache {
        return .{ .gpa = gpa, .capacity = cache_capacity };
    }

    fn deinit(self: *OldReplayCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit(self.gpa);

        self.entries.deinit(self.gpa);
    }

    fn get(
        self: *OldReplayCache,
        path: []const u8,
        lang: language.Name,
        content_hash: [32]u8,
        generation: u64,
    ) ?[]const diagnostic.Diagnostic {
        _ = lang;
        _ = generation;
        const entry = self.entries.getPtr(path) orelse return null;
        if (!std.mem.eql(u8, &entry.content_hash, &content_hash)) return null;

        self.clock += 1;
        entry.last_used = self.clock;

        return entry.diagnostics;
    }

    fn put(
        self: *OldReplayCache,
        path: []const u8,
        lang: language.Name,
        content_hash: [32]u8,
        generation: u64,
        diagnostics: []const diagnostic.Diagnostic,
    ) !void {
        _ = lang;
        _ = generation;
        const arena_ptr = try self.gpa.create(std.heap.ArenaAllocator);
        errdefer self.gpa.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        const owned_path = try arena.dupe(u8, path);
        self.clock += 1;
        const entry: Entry = .{
            .arena = arena_ptr,
            .content_hash = content_hash,
            .diagnostics = try dupeDiagnostics(arena, diagnostics),
            .last_used = self.clock,
        };

        if (self.entries.getPtr(path)) |existing| {
            const old = existing.*;
            const key_ptr = self.entries.getKeyPtr(path).?;
            key_ptr.* = owned_path;
            existing.* = entry;
            old.deinit(self.gpa);

            return;
        }

        if (self.entries.count() >= self.capacity) self.evictOldest();

        try self.entries.put(self.gpa, owned_path, entry);
    }

    fn evictOldest(self: *OldReplayCache) void {
        var oldest_path: ?[]const u8 = null;
        var oldest_used: u64 = std.math.maxInt(u64);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_used < oldest_used) {
                oldest_used = kv.value_ptr.last_used;
                oldest_path = kv.key_ptr.*;
            }
        }

        const path = oldest_path orelse return;
        const removed = self.entries.fetchRemove(path).?;
        removed.value.deinit(self.gpa);
    }
};

fn dupeDiagnostics(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const diagnostic.Diagnostic {
    const out = try arena.alloc(diagnostic.Diagnostic, diagnostics.len);
    for (diagnostics, out) |d, *copy| {
        copy.* = .{
            .rule_id = try arena.dupe(u8, d.rule_id),
            .language = try arena.dupe(u8, d.language),
            .message = try arena.dupe(u8, d.message),
            .range = d.range,
            .severity = d.severity,
            .demoted = d.demoted,
            .maturity = d.maturity,
            .fingerprint = try arena.dupe(u8, d.fingerprint),
            .context = try dupeContext(arena, d.context),
            .fix = try dupeFix(arena, d.fix),
            .suggestions = try dupeSuggestions(arena, d.suggestions),
            .rule_scope = d.rule_scope,
        };
    }

    return out;
}

fn dupeContext(arena: std.mem.Allocator, context: []const diagnostic.Context) ![]const diagnostic.Context {
    const out = try arena.alloc(diagnostic.Context, context.len);
    for (context, out) |entry, *copy| {
        copy.* = .{
            .kind = entry.kind,
            .name = try arena.dupe(u8, entry.name),
            .range = entry.range,
        };
    }

    return out;
}

fn dupeFix(arena: std.mem.Allocator, fix: ?diagnostic.Fix) !?diagnostic.Fix {
    const value = fix orelse return null;

    return .{
        .range = value.range,
        .replacement = try arena.dupe(u8, value.replacement),
        .safety = value.safety,
    };
}

fn dupeSuggestions(arena: std.mem.Allocator, suggestions: []const diagnostic.Suggestion) ![]const diagnostic.Suggestion {
    const out = try arena.alloc(diagnostic.Suggestion, suggestions.len);
    for (suggestions, out) |entry, *copy| {
        copy.* = .{
            .label = try arena.dupe(u8, entry.label),
            .range = entry.range,
            .replacement = try arena.dupe(u8, entry.replacement),
        };
    }

    return out;
}

fn fillPath(path: *Path, id: u64) void {
    @memset(path, '0');
    @memcpy(path[0..11], "src/replay/");
    @memcpy(path[28..32], ".zig");
    var value = id;
    var index: usize = 28;
    while (index > 11) {
        index -= 1;
        path[index] = @intCast(value % 10 + '0');
        value /= 10;
    }
}

fn fillHash(hash: *ContentHash, path: *const Path) void {
    for (0..4) |word_index| {
        const word = std.hash.Wyhash.hash(word_index, path);
        for (0..8) |byte_index| {
            const shift: u6 = @intCast(byte_index * 8);
            hash[word_index * 8 + byte_index] = @truncate(word >> shift);
        }
    }
}

fn initCache(comptime Cache: type, gpa: std.mem.Allocator) !Cache {
    if (Cache == replay.ReplayCache) return try Cache.init(gpa, capacity);
    return Cache.init(gpa, capacity);
}

fn seed(comptime Cache: type, cache: *Cache, data: Data) !void {
    for (0..capacity) |index| {
        try cache.put(&data.paths[index], .ts, data.hashes[index], 0, &.{});
    }
}

fn seedNatural(comptime Cache: type, cache: *Cache, data: Data) !void {
    for (0..capacity) |index| {
        try cache.put(&data.natural_paths[index], .ts, data.natural_hashes[index], 0, &.{});
    }
}

fn runGets(comptime Cache: type, cache: *Cache, data: Data, operations: usize, stale: bool) Measurement {
    var hits: u64 = 0;
    var misses: u64 = 0;
    var checksum: u64 = 0;
    for (0..operations) |operation| {
        const index = operation % capacity;
        const hash = if (stale) data.stale_hashes[index] else data.hashes[index];
        if (cache.get(&data.paths[index], .ts, hash, 0)) |diagnostics| {
            hits += 1;
            checksum +%= index + diagnostics.len + 1;
        } else {
            misses += 1;
            checksum +%= index *% 3 +% 7;
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .elapsed_ns = 0,
        .operations = operations,
        .hits = hits,
        .misses = misses,
        .checksum = checksum,
    };
}

fn runInsertions(comptime Cache: type, cache: *Cache, data: Data, operations: usize) !Measurement {
    var checksum: u64 = 0;
    for (0..operations) |operation| {
        const index = capacity + operation;
        try cache.put(&data.paths[index], .ts, data.hashes[index], 0, &.{});
        checksum +%= index;
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .elapsed_ns = 0,
        .operations = operations,
        .hits = 0,
        .misses = 0,
        .checksum = checksum,
    };
}

fn runMixed(comptime Cache: type, cache: *Cache, data: Data, operations: usize) !Measurement {
    var hits: u64 = 0;
    var misses: u64 = 0;
    var checksum: u64 = 0;
    for (data.trace[0..operations]) |operation| {
        switch (operation.kind) {
            .get, .get_stale => {
                const hash = if (operation.kind == .get_stale)
                    data.natural_stale_hashes[operation.path_index]
                else
                    data.natural_hashes[operation.path_index];
                if (cache.get(&data.natural_paths[operation.path_index], .ts, hash, 0)) |diagnostics| {
                    hits += 1;
                    checksum +%= operation.path_index + diagnostics.len + 1;
                } else {
                    misses += 1;
                    checksum +%= operation.path_index *% 3 +% 7;
                }
            },
            .put => {
                try cache.put(
                    &data.natural_paths[operation.path_index],
                    .ts,
                    data.natural_hashes[operation.path_index],
                    0,
                    &.{},
                );
                checksum +%= operation.path_index *% 5 +% 11;
            },
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .elapsed_ns = 0,
        .operations = operations,
        .hits = hits,
        .misses = misses,
        .checksum = checksum,
    };
}

fn timedGets(
    comptime Cache: type,
    cache: *Cache,
    io: std.Io,
    data: Data,
    stale: bool,
) Measurement {
    const started = std.Io.Clock.awake.now(io);
    var result = runGets(Cache, cache, data, hot_operations, stale);
    result.elapsed_ns = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    return result;
}

fn benchmarkGets(
    gpa: std.mem.Allocator,
    io: std.Io,
    data: Data,
    stale: bool,
) !MeasurementPair {
    var current_cache = try initCache(replay.ReplayCache, gpa);
    defer current_cache.deinit();
    try seed(replay.ReplayCache, &current_cache, data);
    _ = runGets(replay.ReplayCache, &current_cache, data, warmup_operations, stale);

    var prior_cache = try initCache(OldReplayCache, gpa);
    defer prior_cache.deinit();
    try seed(OldReplayCache, &prior_cache, data);
    _ = runGets(OldReplayCache, &prior_cache, data, warmup_operations, stale);

    var current_elapsed: [sample_count]u64 = undefined;
    var prior_elapsed: [sample_count]u64 = undefined;
    var current_result: Measurement = undefined;
    var prior_result: Measurement = undefined;
    // Alternate which implementation runs first so thermal drift and scheduler
    // noise do not consistently favor one side of the comparison.
    for (0..sample_count) |sample| {
        if (sample % 2 == 0) {
            current_result = timedGets(replay.ReplayCache, &current_cache, io, data, stale);
            prior_result = timedGets(OldReplayCache, &prior_cache, io, data, stale);
        } else {
            prior_result = timedGets(OldReplayCache, &prior_cache, io, data, stale);
            current_result = timedGets(replay.ReplayCache, &current_cache, io, data, stale);
        }
        current_elapsed[sample] = current_result.elapsed_ns;
        prior_elapsed[sample] = prior_result.elapsed_ns;
    }
    current_result.elapsed_ns = median(&current_elapsed);
    prior_result.elapsed_ns = median(&prior_elapsed);
    return .{ .current = current_result, .prior = prior_result };
}

fn warmupFresh(
    comptime Cache: type,
    comptime workload: FreshWorkload,
    gpa: std.mem.Allocator,
    data: Data,
) !void {
    switch (workload) {
        .insertion => {
            var cache = try initCache(Cache, gpa);
            defer cache.deinit();
            try seed(Cache, &cache, data);
            _ = try runInsertions(Cache, &cache, data, 128);
        },
        .mixed => {
            var cache = try initCache(Cache, gpa);
            defer cache.deinit();
            try seedNatural(Cache, &cache, data);
            _ = try runMixed(Cache, &cache, data, warmup_operations);
        },
        .retention => {},
    }
}

fn runRetention(comptime Cache: type, cache: *Cache, data: Data) Measurement {
    var hits: u64 = 0;
    var misses: u64 = 0;
    var checksum: u64 = 0;
    for (0..capacity) |index| {
        if (cache.get(&data.natural_paths[index], .ts, data.natural_hashes[index], 0)) |_| {
            hits += 1;
            checksum +%= index + 1;
        } else {
            misses += 1;
            checksum +%= index *% 3 +% 7;
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .elapsed_ns = 0,
        .operations = capacity,
        .hits = hits,
        .misses = misses,
        .checksum = checksum,
    };
}

fn timedFresh(
    comptime Cache: type,
    comptime workload: FreshWorkload,
    gpa: std.mem.Allocator,
    io: std.Io,
    data: Data,
) !Measurement {
    // Insertions and the mixed trace mutate eviction order and membership. Seed
    // a fresh cache for every sample so later samples do not measure new states.
    var cache = try initCache(Cache, gpa);
    defer cache.deinit();
    switch (workload) {
        .insertion => try seed(Cache, &cache, data),
        .mixed, .retention => try seedNatural(Cache, &cache, data),
    }

    // Setup is outside the timed interval. Only the workload implementation is
    // compared, not allocator warmup or seed construction.
    const started = std.Io.Clock.awake.now(io);
    var result = switch (workload) {
        .insertion => try runInsertions(Cache, &cache, data, insertion_operations),
        .mixed => try runMixed(Cache, &cache, data, mixed_operations),
        .retention => runRetention(Cache, &cache, data),
    };
    result.elapsed_ns = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    return result;
}

fn benchmarkFresh(
    comptime workload: FreshWorkload,
    gpa: std.mem.Allocator,
    io: std.Io,
    data: Data,
) !MeasurementPair {
    try warmupFresh(replay.ReplayCache, workload, gpa, data);
    try warmupFresh(OldReplayCache, workload, gpa, data);

    var current_elapsed: [sample_count]u64 = undefined;
    var prior_elapsed: [sample_count]u64 = undefined;
    var current_result: Measurement = undefined;
    var prior_result: Measurement = undefined;
    for (0..sample_count) |sample| {
        if (sample % 2 == 0) {
            current_result = try timedFresh(replay.ReplayCache, workload, gpa, io, data);
            prior_result = try timedFresh(OldReplayCache, workload, gpa, io, data);
        } else {
            prior_result = try timedFresh(OldReplayCache, workload, gpa, io, data);
            current_result = try timedFresh(replay.ReplayCache, workload, gpa, io, data);
        }
        current_elapsed[sample] = current_result.elapsed_ns;
        prior_elapsed[sample] = prior_result.elapsed_ns;
    }
    current_result.elapsed_ns = median(&current_elapsed);
    prior_result.elapsed_ns = median(&prior_elapsed);
    return .{ .current = current_result, .prior = prior_result };
}

fn median(samples: *[sample_count]u64) u64 {
    // Use the same outlier-resistant summary for both implementations. With an
    // even sample count this selects the upper median consistently.
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[sample_count / 2];
}

fn printMeasurement(
    writer: *std.Io.Writer,
    implementation: []const u8,
    workload: []const u8,
    measurement: Measurement,
) !void {
    try writer.print(
        "implementation={s} workload={s} capacity={d} samples={d} operations={d} hits={d} misses={d} median_ns={d} ns_per_op={d} checksum={d}\n",
        .{
            implementation,
            workload,
            capacity,
            sample_count,
            measurement.operations,
            measurement.hits,
            measurement.misses,
            measurement.elapsed_ns,
            measurement.elapsed_ns / measurement.operations,
            measurement.checksum,
        },
    );
}

fn printMeasurements(
    writer: *std.Io.Writer,
    workload: []const u8,
    measurements: MeasurementPair,
) !void {
    try printMeasurement(writer, "current", workload, measurements.current);
    try printMeasurement(writer, "prior", workload, measurements.prior);
}

pub fn main(init: std.process.Init) !void {
    const data = try Data.init(init.gpa);
    defer data.deinit(init.gpa);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try printMeasurements(&stdout.interface, "hot_hits", try benchmarkGets(init.gpa, init.io, data, false));
    try printMeasurements(&stdout.interface, "stale_content_misses", try benchmarkGets(init.gpa, init.io, data, true));
    try printMeasurements(&stdout.interface, "full_capacity_unique_insert", try benchmarkFresh(.insertion, init.gpa, init.io, data));
    try printMeasurements(&stdout.interface, "natural_retention", try benchmarkFresh(.retention, init.gpa, init.io, data));
    try printMeasurements(&stdout.interface, "mixed_editor_trace", try benchmarkFresh(.mixed, init.gpa, init.io, data));
    try stdout.interface.flush();
}

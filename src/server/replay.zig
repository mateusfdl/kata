const std = @import("std");

const diagnostic = @import("engine").diagnostic;
const language = @import("engine").language;
const node_pool = @import("shared").node_pool;

pub const default_capacity: usize = 2048;

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    language: language.Name,
    content_hash: [32]u8,
    diagnostics: []const diagnostic.Diagnostic,
    previous: ?*Entry = null,
    next: ?*Entry = null,

    fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
};

const Key = struct {
    path: []const u8,
    language: language.Name,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.path);
        const language_tag: u8 = @intFromEnum(key.language);
        hasher.update(std.mem.asBytes(&language_tag));
        return hasher.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.language == b.language and std.mem.eql(u8, a.path, b.path);
    }
};

const EntryMap = std.HashMapUnmanaged(Key, *Entry, KeyContext, 80);

const EntryPool = node_pool.NodePoolType(@sizeOf(Entry), @alignOf(Entry));
const max_map_capacity = (((@as(u64, 1) << 31) * 80) - 1) / 100;

pub const ReplayCache = struct {
    gpa: std.mem.Allocator,
    capacity: usize,
    entries: EntryMap = .empty,
    pool: ?EntryPool = null,
    oldest: ?*Entry = null,
    newest: ?*Entry = null,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !ReplayCache {
        if (capacity == 0 or capacity > max_map_capacity) return error.InvalidReplayCapacity;
        return .{ .gpa = gpa, .capacity = capacity };
    }

    pub fn deinit(self: *ReplayCache) void {
        // Save next before destroying each arena because the link fields live in
        // the pooled entry whose contents become invalid after release.
        var current = self.oldest;
        while (current) |entry| {
            const next = entry.next;
            self.destroyEntry(entry);
            current = next;
        }
        self.entries.deinit(self.gpa);
        if (self.pool) |*pool| pool.deinit();
        self.* = undefined;
    }

    pub fn get(
        self: *ReplayCache,
        path: []const u8,
        lang: language.Name,
        content_hash: [32]u8,
    ) ?[]const diagnostic.Diagnostic {
        const entry = self.entries.get(.{ .path = path, .language = lang }) orelse return null;
        // Stale content is a miss and must not make the old entry more recent.
        if (!std.mem.eql(u8, &entry.content_hash, &content_hash)) return null;
        self.promote(entry);
        return entry.diagnostics;
    }

    pub fn put(
        self: *ReplayCache,
        path: []const u8,
        lang: language.Name,
        content_hash: [32]u8,
        diagnostics: []const diagnostic.Diagnostic,
    ) !void {
        try self.ensureStorage();
        // Fully build the replacement before changing the map or LRU list. An
        // allocation failure therefore preserves the old value and exact order.
        const entry = try self.createEntry(path, lang, content_hash, diagnostics);
        errdefer self.destroyEntry(entry);

        const key = entryKey(entry);
        if (self.entries.get(key)) |old| {
            std.debug.assert(self.entries.remove(key));
            self.unlink(old);
            self.destroyEntry(old);
        } else if (self.entries.count() == self.capacity) {
            const old = self.oldest.?;
            std.debug.assert(self.entries.remove(entryKey(old)));
            self.unlink(old);
            self.destroyEntry(old);
        }

        self.entries.putAssumeCapacity(key, entry);
        self.pushNewest(entry);
    }

    fn createEntry(
        self: *ReplayCache,
        path: []const u8,
        lang: language.Name,
        content_hash: [32]u8,
        diagnostics: []const diagnostic.Diagnostic,
    ) !*Entry {
        const pool = &self.pool.?;
        const raw = pool.acquire() orelse return error.ReplayPoolExhausted;
        const entry: *Entry = @ptrCast(raw);
        entry.arena = .init(self.gpa);
        errdefer {
            entry.arena.deinit();
            pool.release(raw);
        }
        const arena = entry.arena.allocator();
        // The entry arena owns the path bytes used by the map key and every
        // diagnostic child allocation. The language enum needs no copy.
        entry.path = try arena.dupe(u8, path);
        entry.language = lang;
        entry.content_hash = content_hash;
        entry.diagnostics = try dupeDiagnostics(arena, diagnostics);
        entry.previous = null;
        entry.next = null;
        return entry;
    }

    fn ensureStorage(self: *ReplayCache) !void {
        if (self.pool != null) return;

        // Empty caches allocate nothing. On first put, reserve the complete map
        // so steady-state replacement can use putAssumeCapacity without failure.
        const map_capacity: u32 = @intCast(self.capacity);
        var entries: EntryMap = .empty;
        try entries.ensureTotalCapacity(self.gpa, map_capacity);
        errdefer entries.deinit(self.gpa);
        // Transactional build-before-evict needs one transient node beyond the
        // logical capacity. It is returned after replacement or eviction.
        const pool = try EntryPool.init(self.gpa, try std.math.add(usize, self.capacity, 1));
        self.entries = entries;
        self.pool = pool;
    }

    fn promote(self: *ReplayCache, entry: *Entry) void {
        if (self.newest == entry) return;
        self.unlink(entry);
        self.pushNewest(entry);
    }

    fn pushNewest(self: *ReplayCache, entry: *Entry) void {
        entry.previous = self.newest;
        entry.next = null;
        if (self.newest) |newest| newest.next = entry else self.oldest = entry;
        self.newest = entry;
    }

    fn unlink(self: *ReplayCache, entry: *Entry) void {
        if (entry.previous) |previous| previous.next = entry.next else self.oldest = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.newest = entry.previous;
        entry.previous = null;
        entry.next = null;
    }

    fn destroyEntry(self: *ReplayCache, entry: *Entry) void {
        entry.deinit();
        self.pool.?.release(@ptrCast(entry));
    }

    pub fn pooledEntries(self: *const ReplayCache) usize {
        return if (self.pool) |*pool| pool.inUseCount() else 0;
    }

    pub fn availablePoolEntries(self: *const ReplayCache) usize {
        return if (self.pool) |*pool| pool.available() else 0;
    }
};

fn entryKey(entry: *const Entry) Key {
    return .{ .path = entry.path, .language = entry.language };
}

fn dupeDiagnostics(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
) ![]const diagnostic.Diagnostic {
    // Request diagnostics borrow parse, rule, and request arenas. Deep-copy all
    // slices so a replay entry has one independent lifetime.
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
            .capped = d.capped,
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

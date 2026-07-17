const std = @import("std");

pub const embedded_source = @embedFile("retired.yaml");

pub const Error = error{ OutOfMemory, InvalidRetiredEntry, MissingRetiredReason };

pub const Entry = union(enum) {
    replaced: []const u8,
    removed: []const u8,
};

pub const Registry = std.StringHashMapUnmanaged(Entry);

pub const Diagnostic = struct {
    line: u32 = 0,
};

const Pending = struct {
    id: []const u8,
    line: u32,
    replaced: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Registry {
    var registry: Registry = .empty;
    var pending: ?Pending = null;
    var line_no: u32 = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw_line, " \r");
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (line[0] != ' ') {
            try finalize(arena, &registry, pending, diag);
            pending = try startEntry(arena, line, line_no, diag);

            continue;
        }

        var entry = pending orelse return fail(diag, line_no, error.InvalidRetiredEntry);
        try setProperty(arena, &entry, trimmed, line_no, diag);
        pending = entry;
    }
    try finalize(arena, &registry, pending, diag);

    return registry;
}

pub fn merge(arena: std.mem.Allocator, base: *Registry, overlay: Registry) !void {
    var it = overlay.iterator();
    while (it.next()) |entry| {
        try base.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidRetiredEntry => "invalid retired entry",
        error.MissingRetiredReason => "retired id needs replaced-by or reason",
        else => @errorName(err),
    };
}

fn startEntry(arena: std.mem.Allocator, line: []const u8, line_no: u32, diag: *Diagnostic) Error!Pending {
    if (line[line.len - 1] != ':') return fail(diag, line_no, error.InvalidRetiredEntry);
    const id = line[0 .. line.len - 1];
    if (id.len == 0) return fail(diag, line_no, error.InvalidRetiredEntry);

    return .{ .id = try arena.dupe(u8, id), .line = line_no };
}

fn setProperty(arena: std.mem.Allocator, entry: *Pending, trimmed: []const u8, line_no: u32, diag: *Diagnostic) Error!void {
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return fail(diag, line_no, error.InvalidRetiredEntry);
    const key = trimmed[0..colon];
    const value = unquote(std.mem.trim(u8, trimmed[colon + 1 ..], " "));
    if (value.len == 0) return fail(diag, line_no, error.InvalidRetiredEntry);

    if (std.mem.eql(u8, key, "replaced-by")) {
        entry.replaced = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "reason")) {
        entry.reason = try arena.dupe(u8, value);
    } else {
        return fail(diag, line_no, error.InvalidRetiredEntry);
    }
}

fn finalize(arena: std.mem.Allocator, registry: *Registry, pending: ?Pending, diag: *Diagnostic) Error!void {
    const entry = pending orelse return;
    if (entry.replaced) |target| {
        try registry.put(arena, entry.id, .{ .replaced = target });

        return;
    }
    if (entry.reason) |reason| {
        try registry.put(arena, entry.id, .{ .removed = reason });

        return;
    }

    return fail(diag, entry.line, error.MissingRetiredReason);
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];

    return value;
}

fn fail(diag: *Diagnostic, line: u32, err: Error) Error {
    diag.* = .{ .line = line };

    return err;
}

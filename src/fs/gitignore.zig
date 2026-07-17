const std = @import("std");

pub const Verdict = enum { ignored, included, unmatched };

pub const Scope = struct {
    dir_path: []const u8,
    patterns: []const Pattern,

    pub fn parse(
        arena: std.mem.Allocator,
        dir_path: []const u8,
        bytes: []const u8,
    ) error{OutOfMemory}!Scope {
        var patterns: std.ArrayList(Pattern) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const pattern = try Pattern.parse(arena, line) orelse continue;
            try patterns.append(arena, pattern);
        }

        return .{ .dir_path = dir_path, .patterns = try patterns.toOwnedSlice(arena) };
    }

    pub fn match(scope: Scope, rel_to_scope: []const u8, is_dir: bool) ?Verdict {
        var i = scope.patterns.len;
        while (i > 0) {
            i -= 1;
            const pattern = scope.patterns[i];
            if (pattern.matches(rel_to_scope, is_dir)) {
                return if (pattern.negated) .included else .ignored;
            }
        }

        return null;
    }
};

pub const Pattern = struct {
    negated: bool,
    dir_only: bool,
    anchored: bool,
    segments: []const []const u8,

    pub fn parse(arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}!?Pattern {
        var rest = trimTrailingSpaces(std.mem.trimEnd(u8, line, "\r"));
        if (rest.len == 0 or rest[0] == '#') return null;

        var negated = false;
        if (rest[0] == '!') {
            negated = true;
            rest = rest[1..];
        }

        var dir_only = false;
        if (rest.len > 0 and rest[rest.len - 1] == '/') {
            dir_only = true;
            rest = std.mem.trimEnd(u8, rest, "/");
        }

        const anchored = std.mem.indexOfScalar(u8, rest, '/') != null;
        rest = std.mem.trimStart(u8, rest, "/");
        if (rest.len == 0) return null;

        var segments: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, rest, '/');
        while (parts.next()) |part| {
            try segments.append(arena, try arena.dupe(u8, part));
        }

        return .{
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .segments = try segments.toOwnedSlice(arena),
        };
    }

    pub fn matches(pattern: Pattern, rel_path: []const u8, is_dir: bool) bool {
        if (pattern.dir_only and !is_dir) return false;
        if (!pattern.anchored) return matchSegment(pattern.segments[0], basename(rel_path));

        return matchPath(pattern.segments, rel_path);
    }
};

fn basename(rel_path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, rel_path, '/') orelse return rel_path;

    return rel_path[idx + 1 ..];
}

fn matchPath(segments: []const []const u8, path: []const u8) bool {
    if (segments.len == 0) return path.len == 0;

    const segment = segments[0];
    if (std.mem.eql(u8, segment, "**")) {
        if (segments.len == 1) return path.len > 0;

        var rest = path;
        while (true) {
            if (matchPath(segments[1..], rest)) return true;
            const idx = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
            rest = rest[idx + 1 ..];
        }
    }

    if (path.len == 0) return false;
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    if (!matchSegment(segment, path[0..end])) return false;
    if (end == path.len) return segments.len == 1;

    return matchPath(segments[1..], path[end + 1 ..]);
}

fn matchSegment(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;

    switch (pattern[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= name.len) : (i += 1) {
                if (matchSegment(pattern[1..], name[i..])) return true;
            }

            return false;
        },
        '?' => {
            if (name.len == 0) return false;

            return matchSegment(pattern[1..], name[1..]);
        },
        '[' => {
            if (name.len == 0) return false;
            if (matchClass(pattern, name[0])) |class| {
                if (!class.matched) return false;

                return matchSegment(pattern[class.len..], name[1..]);
            }
            if (name[0] != '[') return false;

            return matchSegment(pattern[1..], name[1..]);
        },
        '\\' => {
            if (name.len == 0) return false;
            if (pattern.len == 1) return name.len == 1 and name[0] == '\\';
            if (name[0] != pattern[1]) return false;

            return matchSegment(pattern[2..], name[1..]);
        },
        else => {
            if (name.len == 0 or name[0] != pattern[0]) return false;

            return matchSegment(pattern[1..], name[1..]);
        },
    }
}

const Class = struct {
    len: usize,
    matched: bool,
};

fn matchClass(pattern: []const u8, ch: u8) ?Class {
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }

    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return .{ .len = i + 1, .matched = matched != negate };
        }
        first = false;
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (ch >= pattern[i] and ch <= pattern[i + 2]) matched = true;
            i += 3;
        } else {
            if (pattern[i] == ch) matched = true;
            i += 1;
        }
    }

    return null;
}

fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        if (end > 1 and line[end - 2] == '\\') break;
        end -= 1;
    }

    return line[0..end];
}

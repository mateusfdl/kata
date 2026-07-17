const std = @import("std");

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
};

fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        if (end > 1 and line[end - 2] == '\\') break;
        end -= 1;
    }

    return line[0..end];
}

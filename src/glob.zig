const std = @import("std");

pub fn match(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[pattern.len - 1] == '/') return matchDirPrefix(pattern[0 .. pattern.len - 1], path);
    return core(pattern, path);
}

fn matchDirPrefix(dir_pattern: []const u8, path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        if (core(dir_pattern, path[0..i])) return true;
    }
    return false;
}

fn core(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    return switch (pattern[0]) {
        '*' => if (pattern.len >= 2 and pattern[1] == '*')
            matchStarStar(pattern[2..], text)
        else
            matchStar(pattern[1..], text),
        '?' => text.len != 0 and text[0] != '/' and core(pattern[1..], text[1..]),
        else => text.len != 0 and text[0] == pattern[0] and core(pattern[1..], text[1..]),
    };
}

fn matchStar(rest: []const u8, text: []const u8) bool {
    var i: usize = 0;
    while (true) {
        if (core(rest, text[i..])) return true;
        if (i == text.len or text[i] == '/') return false;
        i += 1;
    }
}

fn matchStarStar(rest: []const u8, text: []const u8) bool {
    if (rest.len != 0 and rest[0] == '/' and core(rest[1..], text)) return true;
    var i: usize = 0;
    while (true) {
        if (core(rest, text[i..])) return true;
        if (i == text.len) return false;
        i += 1;
    }
}

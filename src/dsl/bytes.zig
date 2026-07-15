const std = @import("std");

pub const LexemeByte = enum(u8) {
    space = ' ',
    tab = '\t',
    carriage_return = '\r',
    line_feed = '\n',
    double_quote = '"',
    backslash = '\\',
    underscore = '_',
    dash = '-',
    lowercase_n = 'n',
    lowercase_r = 'r',
    lowercase_t = 't',
    equal_sign = '=',
    ampersand = '&',
    pipe = '|',
};

pub fn isSymbol(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        @intFromEnum(LexemeByte.underscore), @intFromEnum(LexemeByte.dash) => true,
        else => false,
    };
}

pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        @intFromEnum(LexemeByte.space),
        @intFromEnum(LexemeByte.tab),
        @intFromEnum(LexemeByte.line_feed),
        @intFromEnum(LexemeByte.carriage_return),
        => true,
        else => false,
    };
}

pub fn isLineBreak(c: u8) bool {
    return switch (c) {
        @intFromEnum(LexemeByte.line_feed), @intFromEnum(LexemeByte.carriage_return) => true,
        else => false,
    };
}

pub fn isValidEscape(c: u8) bool {
    return decodedEscape(c) != null;
}

pub fn decodedEscape(c: u8) ?u8 {
    return switch (c) {
        @intFromEnum(LexemeByte.backslash) => @intFromEnum(LexemeByte.backslash),
        @intFromEnum(LexemeByte.double_quote) => @intFromEnum(LexemeByte.double_quote),
        @intFromEnum(LexemeByte.lowercase_n) => @intFromEnum(LexemeByte.line_feed),
        @intFromEnum(LexemeByte.lowercase_r) => @intFromEnum(LexemeByte.carriage_return),
        @intFromEnum(LexemeByte.lowercase_t) => @intFromEnum(LexemeByte.tab),
        else => null,
    };
}

pub fn isLexemeByte(c: u8, expected: LexemeByte) bool {
    return c == @intFromEnum(expected);
}

pub const call_matches = "matches";
pub const call_glob = "glob";
pub const call_any_of = "anyOf";
pub const call_none_of = "noneOf";
pub const call_starts_with = "startsWith";
pub const call_ends_with = "endsWith";
pub const call_contains = "contains";

pub const MessageToken = union(enum) {
    literal: []const u8,
    placeholder: []const u8,
};

pub fn scanMessage(
    arena: std.mem.Allocator,
    message: []const u8,
) error{ OutOfMemory, InvalidPlaceholder }!?[]const MessageToken {
    if (std.mem.indexOfAny(u8, message, "{}") == null) return null;

    var tokens: std.ArrayList(MessageToken) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < message.len) {
        const c = message[i];
        if (c == '{') {
            if (i + 1 < message.len and message[i + 1] == '{') {
                try literal.append(arena, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, message, i + 1, '}') orelse
                return error.InvalidPlaceholder;
            if (literal.items.len > 0)
                try tokens.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });
            try tokens.append(arena, .{ .placeholder = message[i + 1 .. close] });
            i = close + 1;
            continue;
        }
        if (c == '}') {
            if (i + 1 < message.len and message[i + 1] == '}') {
                try literal.append(arena, '}');
                i += 2;
                continue;
            }
            return error.InvalidPlaceholder;
        }
        try literal.append(arena, c);
        i += 1;
    }

    if (literal.items.len > 0)
        try tokens.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });

    return try tokens.toOwnedSlice(arena);
}

pub fn dupeAll(arena: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try arena.dupe(u8, item);
    return out;
}

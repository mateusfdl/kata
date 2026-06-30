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

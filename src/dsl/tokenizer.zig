const std = @import("std");
const bytes = @import("bytes.zig");

const LexemeByte = bytes.LexemeByte;

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const TokenKind = enum {
    left_brace,
    right_brace,
    left_paren,
    right_paren,
    left_bracket,
    right_bracket,
    colon,
    comma,
    capture,
    symbol,
    string,
    number,
    equal_equal,
    bang_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    amp_amp,
    pipe_pipe,
    bang,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    range: Range,
};

pub const Diagnostic = struct {
    line: u32 = 1,
    column: u32 = 1,
};

pub const Error = error{
    InvalidCharacter,
    InvalidCapture,
    InvalidStringEscape,
    UnclosedString,
    InvalidOperator,
};

pub const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    diag: *Diagnostic,

    pub fn init(source: []const u8, diag: *Diagnostic) Tokenizer {
        diag.* = .{};
        return .{ .source = source, .diag = diag };
    }

    pub fn next(self: *Tokenizer) Error!Token {
        self.skipWhitespace();

        const start = self.position();
        const start_index = self.index;
        if (self.index >= self.source.len) return self.token(.eof, start, start_index);

        const c = self.source[self.index];
        switch (c) {
            '{' => return self.advanceToken(.left_brace, start, start_index),
            '}' => return self.advanceToken(.right_brace, start, start_index),
            '(' => return self.advanceToken(.left_paren, start, start_index),
            ')' => return self.advanceToken(.right_paren, start, start_index),
            '[' => return self.advanceToken(.left_bracket, start, start_index),
            ']' => return self.advanceToken(.right_bracket, start, start_index),
            ':' => return self.advanceToken(.colon, start, start_index),
            ',' => return self.advanceToken(.comma, start, start_index),
            '"' => return self.string(start, start_index),
            '@' => return self.capture(start, start_index),
            '=' => return self.requiredPair(.equal_sign, .equal_equal, start, start_index),
            '!' => return self.bang(start, start_index),
            '>' => return self.optionalEquals(.greater, .greater_equal, start, start_index),
            '<' => return self.optionalEquals(.less, .less_equal, start, start_index),
            '&' => return self.requiredPair(.ampersand, .amp_amp, start, start_index),
            '|' => return self.requiredPair(.pipe, .pipe_pipe, start, start_index),
            else => {},
        }

        if (std.ascii.isDigit(c)) return self.number(start, start_index);
        if (bytes.isSymbol(c)) return self.symbol(start, start_index);

        self.failAt(start);
        return error.InvalidCharacter;
    }

    fn advanceToken(self: *Tokenizer, kind: TokenKind, start: Position, start_index: usize) Token {
        self.advance();
        return self.token(kind, start, start_index);
    }

    fn requiredPair(self: *Tokenizer, expected: LexemeByte, kind: TokenKind, start: Position, start_index: usize) Error!Token {
        self.advance();
        if (!self.matchNext(expected)) {
            self.failAt(start);
            return error.InvalidOperator;
        }
        self.advance();
        return self.token(kind, start, start_index);
    }

    fn optionalEquals(self: *Tokenizer, single_kind: TokenKind, equals_kind: TokenKind, start: Position, start_index: usize) Token {
        self.advance();
        if (self.matchNext(.equal_sign)) {
            self.advance();
            return self.token(equals_kind, start, start_index);
        }
        return self.token(single_kind, start, start_index);
    }

    fn bang(self: *Tokenizer, start: Position, start_index: usize) Token {
        self.advance();
        if (self.matchNext(.equal_sign)) {
            self.advance();
            return self.token(.bang_equal, start, start_index);
        }
        return self.token(.bang, start, start_index);
    }

    fn capture(self: *Tokenizer, start: Position, start_index: usize) Error!Token {
        self.advance();
        if (self.index >= self.source.len or !bytes.isSymbol(self.source[self.index])) {
            self.failAt(start);
            return error.InvalidCapture;
        }
        self.consumeSymbolChars();
        return self.token(.capture, start, start_index);
    }

    fn symbol(self: *Tokenizer, start: Position, start_index: usize) Token {
        self.consumeSymbolChars();
        return self.token(.symbol, start, start_index);
    }

    fn number(self: *Tokenizer, start: Position, start_index: usize) Token {
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.advance();
        return self.token(.number, start, start_index);
    }

    fn string(self: *Tokenizer, start: Position, start_index: usize) Error!Token {
        self.advance();
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (bytes.isLexemeByte(c, .double_quote)) {
                self.advance();
                return self.token(.string, start, start_index);
            }
            if (bytes.isLineBreak(c)) {
                self.failAt(self.position());
                return error.UnclosedString;
            }
            if (bytes.isLexemeByte(c, .backslash)) {
                try self.escape();
                continue;
            }
            self.advance();
        }
        self.failAt(start);
        return error.UnclosedString;
    }

    fn escape(self: *Tokenizer) Error!void {
        self.advance();
        if (self.index >= self.source.len) {
            self.failAt(self.position());
            return error.UnclosedString;
        }
        if (!bytes.isValidEscape(self.source[self.index])) {
            self.failAt(self.position());
            return error.InvalidStringEscape;
        }
        self.advance();
    }

    fn consumeSymbolChars(self: *Tokenizer) void {
        while (self.index < self.source.len and bytes.isSymbol(self.source[self.index])) self.advance();
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.index < self.source.len) {
            if (!bytes.isWhitespace(self.source[self.index])) return;
            self.advance();
        }
    }

    fn advance(self: *Tokenizer) void {
        if (bytes.isLexemeByte(self.source[self.index], .line_feed)) {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.index += 1;
    }

    fn token(self: Tokenizer, kind: TokenKind, start: Position, start_index: usize) Token {
        return .{
            .kind = kind,
            .lexeme = self.source[start_index..self.index],
            .range = .{ .start = start, .end = self.position() },
        };
    }

    fn position(self: Tokenizer) Position {
        return .{ .line = self.line, .column = self.column };
    }

    fn matchNext(self: Tokenizer, expected: LexemeByte) bool {
        if (self.index >= self.source.len) return false;
        return bytes.isLexemeByte(self.source[self.index], expected);
    }

    fn failAt(self: *Tokenizer, pos: Position) void {
        self.diag.* = .{ .line = pos.line, .column = pos.column };
    }
};

const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const TokenKind = tokenizer.TokenKind;

fn collectKinds(arena: std.mem.Allocator, source: []const u8) ![]const TokenKind {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init(source, &diag);
    var kinds: std.ArrayList(TokenKind) = .empty;
    while (true) {
        const token = try t.next();
        try kinds.append(arena, token.kind);
        if (token.kind == .eof) break;
    }
    return kinds.toOwnedSlice(arena);
}

fn expectToken(source: []const u8, kind: TokenKind, lexeme: []const u8) !void {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init(source, &diag);
    const token = try t.next();
    try std.testing.expectEqual(kind, token.kind);
    try std.testing.expectEqualStrings(lexeme, token.lexeme);
}

test "tokenizer: tokenizes a representative rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\rule no-console {
        \\  lang ts, tsx
        \\
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @receiver
        \\    }
        \\  }
        \\
        \\  where {
        \\    text(@receiver) == "console" && !capture(@ignored)
        \\  }
        \\
        \\  emit @match {
        \\    message "console is not allowed"
        \\  }
        \\}
        \\
    ;

    const kinds = try collectKinds(arena.allocator(), source);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .symbol,      .symbol,      .left_brace,
        .symbol,      .symbol,      .comma,
        .symbol,      .symbol,      .symbol,
        .capture,     .left_brace,  .symbol,
        .colon,       .symbol,      .left_brace,
        .symbol,      .colon,       .symbol,
        .capture,     .right_brace, .right_brace,
        .symbol,      .left_brace,  .symbol,
        .left_paren,  .capture,     .right_paren,
        .equal_equal, .string,      .amp_amp,
        .bang,        .symbol,      .left_paren,
        .capture,     .right_paren, .right_brace,
        .symbol,      .capture,     .left_brace,
        .symbol,      .string,      .right_brace,
        .right_brace, .eof,
    }, kinds);
}

test "tokenizer: tracks one-based line and column ranges" {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init("\n  match @node", &diag);

    const symbol = try t.next();
    try std.testing.expectEqual(TokenKind.symbol, symbol.kind);
    try std.testing.expectEqual(@as(u32, 2), symbol.range.start.line);
    try std.testing.expectEqual(@as(u32, 3), symbol.range.start.column);
    try std.testing.expectEqual(@as(u32, 2), symbol.range.end.line);
    try std.testing.expectEqual(@as(u32, 8), symbol.range.end.column);

    const capture = try t.next();
    try std.testing.expectEqual(TokenKind.capture, capture.kind);
    try std.testing.expectEqual(@as(u32, 2), capture.range.start.line);
    try std.testing.expectEqual(@as(u32, 9), capture.range.start.column);
    try std.testing.expectEqual(@as(u32, 2), capture.range.end.line);
    try std.testing.expectEqual(@as(u32, 14), capture.range.end.column);
}

test "tokenizer: recognizes all operators and delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try collectKinds(arena.allocator(), "{}()[]:, == != > >= < <= && || !");
    try std.testing.expectEqualSlices(TokenKind, &.{
        .left_brace,
        .right_brace,
        .left_paren,
        .right_paren,
        .left_bracket,
        .right_bracket,
        .colon,
        .comma,
        .equal_equal,
        .bang_equal,
        .greater,
        .greater_equal,
        .less,
        .less_equal,
        .amp_amp,
        .pipe_pipe,
        .bang,
        .eof,
    }, kinds);
}

test "tokenizer: validates supported string escapes" {
    try expectToken("\"a\\\\b\\\"c\\nd\\re\\t\"", .string, "\"a\\\\b\\\"c\\nd\\re\\t\"");
}

test "tokenizer: tokenizes captures symbols strings and numbers" {
    try expectToken("@match", .capture, "@match");
    try expectToken("no-console", .symbol, "no-console");
    try expectToken("30000", .number, "30000");
    try expectToken("\"console\"", .string, "\"console\"");
}

test "tokenizer: tokenizes fragments and bare equals" {
    try expectToken("$callable", .fragment, "$callable");
    try expectToken("=", .equal, "=");
    try expectToken("==", .equal_equal, "==");
}

test "tokenizer: rejects invalid string escapes" {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init("message \"bad\\x\"", &diag);

    _ = try t.next();
    try std.testing.expectError(error.InvalidStringEscape, t.next());
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 14), diag.column);
}

test "tokenizer: rejects unclosed strings" {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init("message \"bad", &diag);

    _ = try t.next();
    try std.testing.expectError(error.UnclosedString, t.next());
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.column);
}

test "tokenizer: rejects comments as invalid characters" {
    var diag: tokenizer.Diagnostic = .{};
    var t = tokenizer.Tokenizer.init("rule a # no comments", &diag);

    _ = try t.next();
    _ = try t.next();
    try std.testing.expectError(error.InvalidCharacter, t.next());
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 8), diag.column);
}

test "tokenizer: rejects incomplete captures and operators" {
    var diag_capture: tokenizer.Diagnostic = .{};
    var capture = tokenizer.Tokenizer.init("@", &diag_capture);
    try std.testing.expectError(error.InvalidCapture, capture.next());
    try std.testing.expectEqual(@as(u32, 1), diag_capture.column);

    var diag_fragment: tokenizer.Diagnostic = .{};
    var fragment = tokenizer.Tokenizer.init("$", &diag_fragment);
    try std.testing.expectError(error.InvalidFragment, fragment.next());
    try std.testing.expectEqual(@as(u32, 1), diag_fragment.column);

    var diag_amp: tokenizer.Diagnostic = .{};
    var amp = tokenizer.Tokenizer.init("&", &diag_amp);
    try std.testing.expectError(error.InvalidOperator, amp.next());
    try std.testing.expectEqual(@as(u32, 1), diag_amp.column);
}

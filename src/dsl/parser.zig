const std = @import("std");
const ast = @import("ast.zig");
const bytes = @import("bytes.zig");
const tokenizer = @import("tokenizer.zig");

const LexemeByte = bytes.LexemeByte;
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;

pub const Diagnostic = tokenizer.Diagnostic;

pub const Error = tokenizer.Error || error{
    OutOfMemory,
    InvalidNumber,
    ExpectedRule,
    ExpectedSymbol,
    ExpectedString,
    ExpectedCapture,
    ExpectedLeftBrace,
    ExpectedRightBrace,
    ExpectedRightParen,
    ExpectedColon,
    ExpectedMessage,
    UnknownClause,
    DuplicateClause,
    MissingEmit,
    MissingMatch,
    MissingLanguage,
    InvalidRuleId,
    InvalidKind,
    InvalidSeverity,
    InvalidExpression,
};

const Keyword = enum {
    rule,
    kind,
    local,
    project,
    lang,
    severity,
    @"error",
    warn,
    exclude,
    paths,
    match,
    where,
    emit,
    message,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: tokenizer.Tokenizer,
    diag: *Diagnostic,
    current: Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Parser {
        var t = tokenizer.Tokenizer.init(source, diag);
        const current = try t.next();
        return .{
            .allocator = allocator,
            .tokenizer = t,
            .diag = diag,
            .current = current,
        };
    }

    pub fn parseFile(self: *Parser) Error!ast.File {
        if (self.current.kind == .eof) {
            self.failAt(self.current);
            return error.ExpectedRule;
        }

        var rules: std.ArrayList(ast.Rule) = .empty;
        while (self.current.kind != .eof) {
            try rules.append(self.allocator, try self.parseRule());
        }

        return .{ .rules = try rules.toOwnedSlice(self.allocator) };
    }

    fn parseRule(self: *Parser) Error!ast.Rule {
        const start = self.current;
        try self.expectKeyword(.rule, error.ExpectedRule);
        const id = try self.expectSymbol(error.ExpectedSymbol);
        if (!isRuleId(id.lexeme)) {
            self.failAt(id);
            return error.InvalidRuleId;
        }
        _ = try self.expect(.left_brace, error.ExpectedLeftBrace);

        var kind: ast.RuleKind = .local;
        var languages: []const []const u8 = &.{};
        var severity: ast.Severity = .@"error";
        var exclude_paths: []const []const u8 = &.{};
        var match_clause: ?ast.Match = null;
        var predicates: std.ArrayList(ast.Predicate) = .empty;
        var emit: ?ast.Emit = null;
        var seen_kind = false;
        var seen_lang = false;
        var seen_severity = false;
        var seen_exclude = false;

        while (self.current.kind != .right_brace) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBrace;
            }
            const clause = try self.expectSymbol(error.UnknownClause);
            const keyword = keywordFromToken(clause) orelse {
                self.failAt(clause);
                return error.UnknownClause;
            };
            switch (keyword) {
                .kind => {
                    try self.rejectDuplicate(clause, &seen_kind);
                    kind = try self.parseKind();
                },
                .lang => {
                    try self.rejectDuplicate(clause, &seen_lang);
                    languages = try self.parseSymbolList();
                },
                .severity => {
                    try self.rejectDuplicate(clause, &seen_severity);
                    severity = try self.parseSeverity();
                },
                .exclude => {
                    try self.rejectDuplicate(clause, &seen_exclude);
                    try self.expectKeyword(.paths, error.ExpectedSymbol);
                    exclude_paths = try self.parseStringOrSymbolList();
                },
                .match => {
                    if (match_clause != null) {
                        self.failAt(clause);
                        return error.DuplicateClause;
                    }
                    match_clause = try self.parseMatch();
                },
                .where => try predicates.append(self.allocator, try self.parseWhere()),
                .emit => {
                    if (emit != null) {
                        self.failAt(clause);
                        return error.DuplicateClause;
                    }
                    emit = try self.parseEmit(clause);
                },
                else => {
                    self.failAt(clause);
                    return error.UnknownClause;
                },
            }
        }

        const end = self.current;
        try self.advance();

        if (emit == null) {
            self.failAt(id);
            return error.MissingEmit;
        }
        if (kind == .local and languages.len == 0) {
            self.failAt(id);
            return error.MissingLanguage;
        }
        if (kind == .local and match_clause == null) {
            self.failAt(id);
            return error.MissingMatch;
        }

        return .{
            .id = id.lexeme,
            .kind = kind,
            .languages = languages,
            .severity = severity,
            .exclude_paths = exclude_paths,
            .match = match_clause,
            .where = try predicates.toOwnedSlice(self.allocator),
            .emit = emit.?,
            .range = .{ .start = start.range.start, .end = end.range.end },
        };
    }

    fn parseKind(self: *Parser) Error!ast.RuleKind {
        const value = try self.expectSymbol(error.ExpectedSymbol);
        if (isKeyword(value, .local)) return .local;
        if (isKeyword(value, .project)) return .project;
        self.failAt(value);
        return error.InvalidKind;
    }

    fn parseSeverity(self: *Parser) Error!ast.Severity {
        const value = try self.expectSymbol(error.ExpectedSymbol);
        if (isKeyword(value, .@"error")) return .@"error";
        if (isKeyword(value, .warn)) return .warn;
        self.failAt(value);
        return error.InvalidSeverity;
    }

    fn parseSymbolList(self: *Parser) Error![]const []const u8 {
        return self.parseList(parseSymbolLexeme);
    }

    fn parseStringOrSymbolList(self: *Parser) Error![]const []const u8 {
        return self.parseList(parseStringOrSymbol);
    }

    fn parseList(self: *Parser, comptime parseItem: fn (*Parser) Error![]const u8) Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        try items.append(self.allocator, try parseItem(self));
        while (try self.consume(.comma)) {
            try items.append(self.allocator, try parseItem(self));
        }
        return items.toOwnedSlice(self.allocator);
    }

    fn parseSymbolLexeme(self: *Parser) Error![]const u8 {
        return (try self.expectSymbol(error.ExpectedSymbol)).lexeme;
    }

    fn parseStringOrSymbol(self: *Parser) Error![]const u8 {
        if (self.current.kind == .string) return self.parseString();
        return (try self.expectSymbol(error.ExpectedSymbol)).lexeme;
    }

    fn parseMatch(self: *Parser) Error!ast.Match {
        if (self.current.kind != .symbol) {
            self.failAt(self.current);
            return error.ExpectedSymbol;
        }
        if (self.currentIs(.kind)) {
            const start = self.current;
            try self.advance();
            const kind = try self.expectSymbol(error.ExpectedSymbol);
            const capture = try self.parseOptionalCapture();
            return .{ .kind = .{
                .kind = kind.lexeme,
                .capture = capture,
                .range = .{ .start = start.range.start, .end = lastRangeEnd(capture, kind) },
            } };
        }
        return .{ .node = try self.parseNodePattern() };
    }

    fn parseNodePattern(self: *Parser) Error!ast.NodePattern {
        const node = try self.expectSymbol(error.ExpectedSymbol);
        const capture = try self.parseOptionalCapture();
        var fields: []const ast.FieldPattern = &.{};
        var end = lastRangeEnd(capture, node);
        if (try self.consume(.left_brace)) {
            var list: std.ArrayList(ast.FieldPattern) = .empty;
            while (self.current.kind != .right_brace) {
                if (self.current.kind == .eof) {
                    self.failAt(self.current);
                    return error.ExpectedRightBrace;
                }
                try list.append(self.allocator, try self.parseFieldPattern());
            }
            end = self.current.range.end;
            try self.advance();
            fields = try list.toOwnedSlice(self.allocator);
        }
        return .{
            .node_kind = .{ .symbol = node.lexeme },
            .capture = capture,
            .fields = fields,
            .range = .{ .start = node.range.start, .end = end },
        };
    }

    fn parseFieldPattern(self: *Parser) Error!ast.FieldPattern {
        const name = try self.expectSymbol(error.ExpectedSymbol);
        _ = try self.expect(.colon, error.ExpectedColon);
        const pattern = try self.parseNodePattern();
        return .{
            .name = name.lexeme,
            .pattern = pattern,
            .range = .{ .start = name.range.start, .end = pattern.range.end },
        };
    }

    fn parseWhere(self: *Parser) Error!ast.Predicate {
        const start = try self.expect(.left_brace, error.ExpectedLeftBrace);
        const expression = try self.parseExpression();
        const end = try self.expect(.right_brace, error.ExpectedRightBrace);
        return .{
            .expression = expression,
            .range = .{ .start = start.range.start, .end = end.range.end },
        };
    }

    fn parseEmit(self: *Parser, start: Token) Error!ast.Emit {
        const capture = try self.expectCapture();
        _ = try self.expect(.left_brace, error.ExpectedLeftBrace);
        try self.expectKeyword(.message, error.ExpectedMessage);
        const message = try self.parseString();
        const end = try self.expect(.right_brace, error.ExpectedRightBrace);
        return .{
            .capture = capture,
            .message = message,
            .range = .{ .start = start.range.start, .end = end.range.end },
        };
    }

    fn parseExpression(self: *Parser) Error!ast.Expression {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!ast.Expression {
        var left = try self.parseAnd();
        while (self.current.kind == .pipe_pipe) {
            try self.advance();
            left = try self.logical(.@"or", left, try self.parseAnd());
        }
        return left;
    }

    fn parseAnd(self: *Parser) Error!ast.Expression {
        var left = try self.parseCompare();
        while (self.current.kind == .amp_amp) {
            try self.advance();
            left = try self.logical(.@"and", left, try self.parseCompare());
        }
        return left;
    }

    fn parseCompare(self: *Parser) Error!ast.Expression {
        var left = try self.parseUnary();
        while (compareOp(self.current.kind)) |op| {
            try self.advance();
            left = try self.compare(op, left, try self.parseUnary());
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!ast.Expression {
        if (self.current.kind == .bang) {
            const token = self.current;
            try self.advance();
            const expression = try self.parseUnary();
            return .{ .negate = .{
                .expression = try self.createExpression(expression),
                .range = .{ .start = token.range.start, .end = expressionEnd(expression) },
            } };
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!ast.Expression {
        switch (self.current.kind) {
            .capture => return .{ .capture = try self.expectCapture() },
            .string => return .{ .string = try self.parseStringLiteral() },
            .number => return .{ .number = try self.parseNumberLiteral() },
            .symbol => return self.parseSymbolExpression(),
            .left_paren => {
                try self.advance();
                const expression = try self.parseExpression();
                _ = try self.expect(.right_paren, error.ExpectedRightParen);
                return expression;
            },
            else => {
                self.failAt(self.current);
                return error.InvalidExpression;
            },
        }
    }

    fn parseSymbolExpression(self: *Parser) Error!ast.Expression {
        const name = try self.expectSymbol(error.ExpectedSymbol);
        if (!try self.consume(.left_paren)) {
            self.failAt(name);
            return error.InvalidExpression;
        }

        var args: std.ArrayList(ast.Expression) = .empty;
        if (self.current.kind != .right_paren) {
            try args.append(self.allocator, try self.parseExpression());
            while (try self.consume(.comma)) {
                try args.append(self.allocator, try self.parseExpression());
            }
        }
        const end = try self.expect(.right_paren, error.ExpectedRightParen);
        return .{ .call = .{
            .name = name.lexeme,
            .args = try args.toOwnedSlice(self.allocator),
            .range = .{ .start = name.range.start, .end = end.range.end },
        } };
    }

    fn parseOptionalCapture(self: *Parser) Error!?ast.Capture {
        if (self.current.kind != .capture) return null;
        return try self.expectCapture();
    }

    fn parseNumberLiteral(self: *Parser) Error!ast.NumberLiteral {
        const token = try self.expect(.number, error.InvalidNumber);
        const value = std.fmt.parseInt(u32, token.lexeme, 10) catch {
            self.failAt(token);
            return error.InvalidNumber;
        };
        return .{ .value = value, .range = token.range };
    }

    fn parseStringLiteral(self: *Parser) Error!ast.StringLiteral {
        const token = try self.expect(.string, error.ExpectedString);
        var decoded: std.ArrayList(u8) = .empty;
        var index: usize = 1;
        while (index + 1 < token.lexeme.len) {
            const c = token.lexeme[index];
            if (!bytes.isLexemeByte(c, .backslash)) {
                try decoded.append(self.allocator, c);
                index += 1;
                continue;
            }
            index += 1;
            try decoded.append(self.allocator, bytes.decodedEscape(token.lexeme[index]).?);
            index += 1;
        }
        return .{ .value = try decoded.toOwnedSlice(self.allocator), .range = token.range };
    }

    fn parseString(self: *Parser) Error![]const u8 {
        return (try self.parseStringLiteral()).value;
    }

    fn expectCapture(self: *Parser) Error!ast.Capture {
        const token = try self.expect(.capture, error.ExpectedCapture);
        return .{ .name = token.lexeme[1..], .range = token.range };
    }

    fn expectKeyword(self: *Parser, keyword: Keyword, failure: Error) Error!void {
        const token = try self.expectSymbol(failure);
        if (isKeyword(token, keyword)) return;
        self.failAt(token);
        return failure;
    }

    fn currentIs(self: Parser, keyword: Keyword) bool {
        return isKeyword(self.current, keyword);
    }

    fn expectSymbol(self: *Parser, failure: Error) Error!Token {
        return self.expect(.symbol, failure);
    }

    fn expect(self: *Parser, kind: TokenKind, failure: Error) Error!Token {
        if (self.current.kind != kind) {
            self.failAt(self.current);
            return failure;
        }
        const token = self.current;
        try self.advance();
        return token;
    }

    fn consume(self: *Parser, kind: TokenKind) Error!bool {
        if (self.current.kind != kind) return false;
        try self.advance();
        return true;
    }

    fn advance(self: *Parser) Error!void {
        self.current = try self.tokenizer.next();
    }

    fn rejectDuplicate(self: *Parser, token: Token, seen: *bool) Error!void {
        if (seen.*) {
            self.failAt(token);
            return error.DuplicateClause;
        }
        seen.* = true;
    }

    fn logical(self: *Parser, op: ast.LogicalOp, left: ast.Expression, right: ast.Expression) Error!ast.Expression {
        return .{ .logical = .{
            .op = op,
            .left = try self.createExpression(left),
            .right = try self.createExpression(right),
            .range = expressionRange(left, right),
        } };
    }

    fn compare(self: *Parser, op: ast.CompareOp, left: ast.Expression, right: ast.Expression) Error!ast.Expression {
        return .{ .compare = .{
            .op = op,
            .left = try self.createExpression(left),
            .right = try self.createExpression(right),
            .range = expressionRange(left, right),
        } };
    }

    fn createExpression(self: *Parser, expression: ast.Expression) Error!*const ast.Expression {
        const pointer = try self.allocator.create(ast.Expression);
        pointer.* = expression;
        return pointer;
    }

    fn failAt(self: *Parser, token: Token) void {
        self.diag.* = .{ .line = token.range.start.line, .column = token.range.start.column };
    }
};

fn isKeyword(token: Token, keyword: Keyword) bool {
    return std.mem.eql(u8, token.lexeme, @tagName(keyword));
}

fn keywordFromToken(token: Token) ?Keyword {
    inline for (std.meta.fields(Keyword)) |field| {
        const keyword: Keyword = @enumFromInt(field.value);
        if (isKeyword(token, keyword)) return keyword;
    }
    return null;
}

fn isRuleId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (bytes.isLexemeByte(id[0], .dash)) return false;
    if (bytes.isLexemeByte(id[id.len - 1], .dash)) return false;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (bytes.isLexemeByte(c, .dash)) continue;
        return false;
    }
    return true;
}

fn compareOp(kind: TokenKind) ?ast.CompareOp {
    return switch (kind) {
        .equal_equal => .eq,
        .bang_equal => .ne,
        .greater => .gt,
        .greater_equal => .ge,
        .less => .lt,
        .less_equal => .le,
        else => null,
    };
}

fn lastRangeEnd(capture: ?ast.Capture, token: Token) tokenizer.Position {
    if (capture) |value| return value.range.end;
    return token.range.end;
}

fn expressionRange(left: ast.Expression, right: ast.Expression) tokenizer.Range {
    return .{ .start = expressionStart(left), .end = expressionEnd(right) };
}

fn expressionStart(expression: ast.Expression) tokenizer.Position {
    return switch (expression) {
        .capture => |value| value.range.start,
        .string => |value| value.range.start,
        .number => |value| value.range.start,
        .call => |value| value.range.start,
        .compare => |value| value.range.start,
        .logical => |value| value.range.start,
        .negate => |value| value.range.start,
    };
}

fn expressionEnd(expression: ast.Expression) tokenizer.Position {
    return switch (expression) {
        .capture => |value| value.range.end,
        .string => |value| value.range.end,
        .number => |value| value.range.end,
        .call => |value| value.range.end,
        .compare => |value| value.range.end,
        .logical => |value| value.range.end,
        .negate => |value| value.range.end,
    };
}

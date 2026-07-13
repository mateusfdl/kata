const std = @import("std");
const ast = @import("ast.zig");
const bytes = @import("bytes.zig");
const tokenizer = @import("tokenizer.zig");

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
    ExpectedLeftBracket,
    ExpectedRightBracket,
    EmptySetLiteral,
    ExpectedRightParen,
    ExpectedColon,
    ExpectedMessage,
    ExpectedEqual,
    InvalidNegatedField,
    UnknownFragment,
    DuplicateFragment,
    UnusedFragment,
    FragmentCaptureConflict,
    UnknownClause,
    DuplicateClause,
    EmptyWhere,
    MissingEmit,
    MissingMatch,
    MissingLanguage,
    InvalidRuleId,
    InvalidKind,
    InvalidSeverity,
    InvalidExpression,
    ExpectedComposition,
    ExpectedComparison,
    NestedComposition,
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
    inside,
    has,
    parent,
    count,
    not,
    in,
    any,
    all,
    pattern,
    until,
};

const Fragment = struct {
    pattern: ast.NodePattern,
    range: tokenizer.Range,
    used: bool,
};

const FieldBlock = struct {
    fields: []const ast.FieldPattern,
    absent_fields: []const []const u8,
    end: tokenizer.Position,
};

const ParsedNodeKind = struct {
    value: ast.NodeKind,
    range: tokenizer.Range,
};

const AnonymousNodeKind = enum {
    allowed,
    rejected,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: tokenizer.Tokenizer,
    diag: *Diagnostic,
    current: Token,
    fragments: std.StringArrayHashMapUnmanaged(Fragment) = .empty,

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
            if (self.currentIs(.pattern)) {
                try self.parseFragmentDeclaration();
                continue;
            }
            try rules.append(self.allocator, try self.parseRule());
        }

        if (rules.items.len == 0) {
            self.failAt(self.current);
            return error.ExpectedRule;
        }
        try self.rejectUnusedFragments();

        return .{ .rules = try rules.toOwnedSlice(self.allocator) };
    }

    fn parseFragmentDeclaration(self: *Parser) Error!void {
        try self.advance();
        const name = try self.expectSymbol(error.ExpectedSymbol);
        _ = try self.expect(.equal, error.ExpectedEqual);
        const pattern = try self.parseNodePattern(.allowed);
        const entry = try self.fragments.getOrPut(self.allocator, name.lexeme);
        if (entry.found_existing) {
            self.failAt(name);
            return error.DuplicateFragment;
        }
        entry.value_ptr.* = .{ .pattern = pattern, .range = name.range, .used = false };
    }

    fn rejectUnusedFragments(self: *Parser) Error!void {
        for (self.fragments.values()) |fragment| {
            if (fragment.used) continue;
            self.diag.* = .{
                .line = fragment.range.start.line,
                .column = fragment.range.start.column,
            };
            return error.UnusedFragment;
        }
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
        var predicates: []const ast.Predicate = &.{};
        var emit: ?ast.Emit = null;
        var seen_kind = false;
        var seen_lang = false;
        var seen_severity = false;
        var seen_exclude = false;
        var seen_where = false;

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
                .where => {
                    try self.rejectDuplicate(clause, &seen_where);
                    predicates = try self.parseWhere();
                },
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
            .where = predicates,
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
        if (self.current.kind == .symbol and self.currentIs(.kind)) {
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
        return .{ .node = try self.parseNodePattern(.rejected) };
    }

    fn parseNodePattern(self: *Parser, anonymous: AnonymousNodeKind) Error!ast.NodePattern {
        if (self.current.kind == .fragment) return self.parseFragmentReference(anonymous);
        const node = try self.parseNodeKind(anonymous);
        const capture = try self.parseOptionalCapture();
        var fields: []const ast.FieldPattern = &.{};
        var absent_fields: []const []const u8 = &.{};
        var end = node.range.end;
        if (capture) |value| end = value.range.end;
        if (try self.consume(.left_brace)) {
            const block = try self.parseFieldBlock();
            fields = block.fields;
            absent_fields = block.absent_fields;
            end = block.end;
        }
        return .{
            .node_kind = node.value,
            .capture = capture,
            .fields = fields,
            .absent_fields = absent_fields,
            .range = .{ .start = node.range.start, .end = end },
        };
    }

    fn parseFieldBlock(self: *Parser) Error!FieldBlock {
        var list: std.ArrayList(ast.FieldPattern) = .empty;
        var absents: std.ArrayList([]const u8) = .empty;
        while (self.current.kind != .right_brace) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBrace;
            }
            if (self.current.kind == .bang) {
                try absents.append(self.allocator, try self.parseAbsentField());
                continue;
            }
            try list.append(self.allocator, try self.parseFieldPattern());
        }
        const end = self.current.range.end;
        try self.advance();
        return .{
            .fields = try list.toOwnedSlice(self.allocator),
            .absent_fields = try absents.toOwnedSlice(self.allocator),
            .end = end,
        };
    }

    fn parseFragmentReference(self: *Parser, anonymous: AnonymousNodeKind) Error!ast.NodePattern {
        const token = self.current;
        try self.advance();
        const entry = self.fragments.getPtr(token.lexeme[1..]) orelse {
            self.failAt(token);
            return error.UnknownFragment;
        };
        entry.used = true;
        const fragment = entry.pattern;
        if (anonymous == .rejected and hasAnonymousRoot(fragment)) {
            self.failAt(token);
            return error.ExpectedSymbol;
        }

        const capture = try self.parseOptionalCapture();
        if (capture != null and fragment.capture != null) {
            self.failAt(token);
            return error.FragmentCaptureConflict;
        }
        var fields = fragment.fields;
        var absent_fields = fragment.absent_fields;
        var end = token.range.end;
        if (capture) |value| end = value.range.end;
        if (try self.consume(.left_brace)) {
            const block = try self.parseFieldBlock();
            fields = try self.concatFields(fragment.fields, block.fields);
            absent_fields = try self.concatAbsent(fragment.absent_fields, block.absent_fields);
            end = block.end;
        }
        return .{
            .node_kind = fragment.node_kind,
            .capture = capture orelse fragment.capture,
            .fields = fields,
            .absent_fields = absent_fields,
            .range = .{ .start = token.range.start, .end = end },
        };
    }

    fn concatFields(
        self: *Parser,
        first: []const ast.FieldPattern,
        second: []const ast.FieldPattern,
    ) Error![]const ast.FieldPattern {
        if (first.len == 0) return second;
        const out = try self.allocator.alloc(ast.FieldPattern, first.len + second.len);
        @memcpy(out[0..first.len], first);
        @memcpy(out[first.len..], second);
        return out;
    }

    fn concatAbsent(
        self: *Parser,
        first: []const []const u8,
        second: []const []const u8,
    ) Error![]const []const u8 {
        if (first.len == 0) return second;
        const out = try self.allocator.alloc([]const u8, first.len + second.len);
        @memcpy(out[0..first.len], first);
        @memcpy(out[first.len..], second);
        return out;
    }

    fn parseAbsentField(self: *Parser) Error![]const u8 {
        _ = try self.expect(.bang, error.InvalidNegatedField);
        const name = try self.expectSymbol(error.ExpectedSymbol);
        if (patternRelation(name.lexeme) != .field) {
            self.failAt(name);
            return error.InvalidNegatedField;
        }
        return name.lexeme;
    }

    fn parseNodeKind(self: *Parser, anonymous: AnonymousNodeKind) Error!ParsedNodeKind {
        switch (self.current.kind) {
            .symbol => {
                const token = try self.expectSymbol(error.ExpectedSymbol);
                return .{ .value = .{ .symbol = token.lexeme }, .range = token.range };
            },
            .string => {
                if (anonymous == .rejected) {
                    self.failAt(self.current);
                    return error.ExpectedSymbol;
                }
                const token = try self.parseStringLiteral();
                return .{ .value = .{ .anonymous = token.value }, .range = token.range };
            },
            .left_bracket => return self.parseAlternation(anonymous),
            else => {
                self.failAt(self.current);
                return error.ExpectedSymbol;
            },
        }
    }

    fn parseAlternation(self: *Parser, anonymous: AnonymousNodeKind) Error!ParsedNodeKind {
        const start = try self.expect(.left_bracket, error.ExpectedSymbol);
        var branches: std.ArrayList(ast.NodePattern) = .empty;
        try branches.append(self.allocator, try self.parseNodePattern(anonymous));
        while (try self.consume(.comma)) {
            if (self.current.kind == .right_bracket) break;
            try branches.append(self.allocator, try self.parseNodePattern(anonymous));
        }
        const end = try self.expect(.right_bracket, error.ExpectedRightBracket);
        return .{
            .value = .{ .alternation = try branches.toOwnedSlice(self.allocator) },
            .range = .{ .start = start.range.start, .end = end.range.end },
        };
    }

    fn parseFieldPattern(self: *Parser) Error!ast.FieldPattern {
        const name = try self.expectSymbol(error.ExpectedSymbol);
        _ = try self.expect(.colon, error.ExpectedColon);
        const pattern = try self.parseNodePattern(.allowed);
        return .{
            .relation = patternRelation(name.lexeme),
            .pattern = pattern,
            .range = .{ .start = name.range.start, .end = pattern.range.end },
        };
    }

    fn parseWhere(self: *Parser) Error![]const ast.Predicate {
        const start = try self.expect(.left_brace, error.ExpectedLeftBrace);
        var predicates: std.ArrayList(ast.Predicate) = .empty;
        while (self.current.kind != .right_brace) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBrace;
            }
            try predicates.append(self.allocator, try self.parsePredicate());
        }
        try self.advance();
        if (predicates.items.len == 0) {
            self.failAt(start);
            return error.EmptyWhere;
        }
        return predicates.toOwnedSlice(self.allocator);
    }

    fn parsePredicate(self: *Parser) Error!ast.Predicate {
        if (try self.groupOp()) |op| return self.parseGroupPredicate(op);
        if (compositionKeyword(self.current)) |keyword| {
            return self.parseCompositionPredicate(keyword);
        }
        return .{ .expression = try self.parseExpression() };
    }

    fn groupOp(self: *Parser) Error!?ast.GroupOp {
        if (self.current.kind != .symbol) return null;
        const op: ast.GroupOp = if (isKeyword(self.current, .any))
            .any
        else if (isKeyword(self.current, .all))
            .all
        else
            return null;
        if ((try self.peek()).kind != .left_brace) return null;
        return op;
    }

    fn parseGroupPredicate(self: *Parser, op: ast.GroupOp) Error!ast.Predicate {
        try self.advance();
        const start = try self.expect(.left_brace, error.ExpectedLeftBrace);
        var predicates: std.ArrayList(ast.Predicate) = .empty;
        while (self.current.kind != .right_brace) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBrace;
            }
            try predicates.append(self.allocator, try self.parsePredicate());
        }
        try self.advance();
        if (predicates.items.len == 0) {
            self.failAt(start);
            return error.EmptyWhere;
        }
        return .{ .group = .{
            .op = op,
            .predicates = try predicates.toOwnedSlice(self.allocator),
        } };
    }

    fn parseCompositionPredicate(self: *Parser, keyword: Keyword) Error!ast.Predicate {
        try self.advance();
        if (keyword == .count) {
            const matcher = try self.parseNestedMatcher();
            const op = compareOp(self.current.kind) orelse {
                self.failAt(self.current);
                return error.ExpectedComparison;
            };
            try self.advance();
            const value = try self.parseNumberLiteral();
            return .{ .count = .{ .matcher = matcher, .op = op, .value = value.value } };
        }

        var negated = false;
        var op = keyword;
        if (op == .not) {
            negated = true;
            const inner = self.current;
            op = compositionKeyword(inner) orelse {
                self.failAt(inner);
                return error.ExpectedComposition;
            };
            if (op != .inside and op != .has and op != .parent) {
                self.failAt(inner);
                return error.ExpectedComposition;
            }
            try self.advance();
        }

        const matcher = try self.parseNestedMatcher();
        var until: []const []const u8 = &.{};
        if (op == .inside and self.currentIs(.until)) {
            try self.advance();
            until = try self.parseSymbolList();
        }

        return .{ .composition = .{
            .op = switch (op) {
                .inside => .inside,
                .has => .has,
                .parent => .parent,
                else => unreachable,
            },
            .negated = negated,
            .matcher = matcher,
            .until = until,
        } };
    }

    fn parseNestedMatcher(self: *Parser) Error!ast.NestedMatcher {
        const subject = try self.expectCapture();
        const node = try self.parseNodeKind(.rejected);
        const capture = try self.parseOptionalCapture();
        var fields: []const ast.FieldPattern = &.{};
        var absent_fields: []const []const u8 = &.{};
        var where: []const ast.Expression = &.{};
        var end = node.range.end;
        if (capture) |value| end = value.range.end;
        if (try self.consume(.left_brace)) {
            var list: std.ArrayList(ast.FieldPattern) = .empty;
            var absents: std.ArrayList([]const u8) = .empty;
            var seen_where = false;
            while (self.current.kind != .right_brace) {
                if (self.current.kind == .eof) {
                    self.failAt(self.current);
                    return error.ExpectedRightBrace;
                }
                if (self.current.kind == .bang) {
                    if (seen_where) {
                        self.failAt(self.current);
                        return error.ExpectedRightBrace;
                    }
                    try absents.append(self.allocator, try self.parseAbsentField());
                    continue;
                }
                const name = try self.expectSymbol(error.ExpectedSymbol);
                if (isKeyword(name, .where) and self.current.kind == .left_brace) {
                    try self.rejectDuplicate(name, &seen_where);
                    where = try self.parseNestedWhere();
                    continue;
                }
                if (seen_where) {
                    self.failAt(name);
                    return error.ExpectedRightBrace;
                }
                _ = try self.expect(.colon, error.ExpectedColon);
                const pattern = try self.parseNodePattern(.allowed);
                try list.append(self.allocator, .{
                    .relation = patternRelation(name.lexeme),
                    .pattern = pattern,
                    .range = .{ .start = name.range.start, .end = pattern.range.end },
                });
            }
            end = self.current.range.end;
            try self.advance();
            fields = try list.toOwnedSlice(self.allocator);
            absent_fields = try absents.toOwnedSlice(self.allocator);
        }
        return .{
            .subject = subject,
            .pattern = .{
                .node_kind = node.value,
                .capture = capture,
                .fields = fields,
                .absent_fields = absent_fields,
                .range = .{ .start = node.range.start, .end = end },
            },
            .where = where,
            .range = .{ .start = subject.range.start, .end = end },
        };
    }

    fn parseNestedWhere(self: *Parser) Error![]const ast.Expression {
        const start = try self.expect(.left_brace, error.ExpectedLeftBrace);
        var expressions: std.ArrayList(ast.Expression) = .empty;
        while (self.current.kind != .right_brace) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBrace;
            }
            if (compositionKeyword(self.current) != null) {
                self.failAt(self.current);
                return error.NestedComposition;
            }
            try expressions.append(self.allocator, try self.parseExpression());
        }
        try self.advance();
        if (expressions.items.len == 0) {
            self.failAt(start);
            return error.EmptyWhere;
        }
        return expressions.toOwnedSlice(self.allocator);
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
        var left = try self.parseMembership();
        while (self.current.kind == .amp_amp) {
            try self.advance();
            left = try self.logical(.@"and", left, try self.parseMembership());
        }
        return left;
    }

    fn parseMembership(self: *Parser) Error!ast.Expression {
        const left = try self.parseCompare();
        var negated = false;
        if (isKeyword(self.current, .not)) {
            if (!isKeyword(try self.peek(), .in)) return left;
            try self.advance();
            negated = true;
        } else if (!isKeyword(self.current, .in)) {
            return left;
        }
        try self.advance();
        const values = try self.parseSetLiteral();
        return .{ .membership = .{
            .subject = try self.createExpression(left),
            .values = values.items,
            .negated = negated,
            .range = .{ .start = expressionStart(left), .end = values.end },
        } };
    }

    fn parseSetLiteral(self: *Parser) Error!struct { items: []const ast.StringLiteral, end: tokenizer.Position } {
        _ = try self.expect(.left_bracket, error.ExpectedLeftBracket);
        var items: std.ArrayList(ast.StringLiteral) = .empty;
        while (self.current.kind != .right_bracket) {
            if (self.current.kind == .eof) {
                self.failAt(self.current);
                return error.ExpectedRightBracket;
            }
            try items.append(self.allocator, try self.parseStringLiteral());
            if (!try self.consume(.comma)) break;
        }
        const end = try self.expect(.right_bracket, error.ExpectedRightBracket);
        if (items.items.len == 0) {
            self.failAt(end);
            return error.EmptySetLiteral;
        }
        return .{ .items = try items.toOwnedSlice(self.allocator), .end = end.range.end };
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
        return self.parseCall(name);
    }

    fn parseCall(self: *Parser, name: Token) Error!ast.Expression {
        var args: std.ArrayList(ast.Expression) = .empty;
        if (self.current.kind != .right_paren) {
            try args.append(self.allocator, try self.parseArgument());
            while (try self.consume(.comma)) {
                try args.append(self.allocator, try self.parseArgument());
            }
        }
        const end = try self.expect(.right_paren, error.ExpectedRightParen);
        return .{ .call = .{
            .name = name.lexeme,
            .args = try args.toOwnedSlice(self.allocator),
            .range = .{ .start = name.range.start, .end = end.range.end },
        } };
    }

    fn parseArgument(self: *Parser) Error!ast.Expression {
        if (self.current.kind != .symbol) return self.parseExpression();
        const name = try self.expectSymbol(error.ExpectedSymbol);
        if (try self.consume(.left_paren)) return self.parseCall(name);
        return .{ .symbol = .{ .name = name.lexeme, .range = name.range } };
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

    fn peek(self: *Parser) Error!Token {
        var ahead = self.tokenizer;
        return ahead.next();
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

fn compositionKeyword(token: Token) ?Keyword {
    if (token.kind != .symbol) return null;
    if (isKeyword(token, .inside)) return .inside;
    if (isKeyword(token, .has)) return .has;
    if (isKeyword(token, .parent)) return .parent;
    if (isKeyword(token, .count)) return .count;
    if (isKeyword(token, .not)) return .not;
    return null;
}

fn hasAnonymousRoot(pattern: ast.NodePattern) bool {
    return switch (pattern.node_kind) {
        .anonymous => true,
        .symbol => false,
        .alternation => |branches| blk: {
            for (branches) |branch| {
                if (hasAnonymousRoot(branch)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn patternRelation(name: []const u8) ast.PatternRelation {
    if (std.mem.eql(u8, name, "child")) return .child;
    if (std.mem.eql(u8, name, "children")) return .children;
    return .{ .field = name };
}

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
    if (bytes.isLexemeByte(id[0], .dash)) return false;
    return !bytes.isLexemeByte(id[id.len - 1], .dash);
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
        .symbol => |value| value.range.start,
        .string => |value| value.range.start,
        .number => |value| value.range.start,
        .call => |value| value.range.start,
        .compare => |value| value.range.start,
        .logical => |value| value.range.start,
        .negate => |value| value.range.start,
        .membership => |value| value.range.start,
    };
}

fn expressionEnd(expression: ast.Expression) tokenizer.Position {
    return switch (expression) {
        .capture => |value| value.range.end,
        .symbol => |value| value.range.end,
        .string => |value| value.range.end,
        .number => |value| value.range.end,
        .call => |value| value.range.end,
        .compare => |value| value.range.end,
        .logical => |value| value.range.end,
        .negate => |value| value.range.end,
        .membership => |value| value.range.end,
    };
}

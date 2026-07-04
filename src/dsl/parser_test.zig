const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

fn parse(allocator: std.mem.Allocator, source: []const u8, diag: *parser.Diagnostic) !ast.File {
    var p = try parser.Parser.init(allocator, source, diag);
    return p.parseFile();
}

fn expectFieldRelation(expected: []const u8, relation: ast.PatternRelation) !void {
    switch (relation) {
        .field => |field| try std.testing.expectEqualStrings(expected, field),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: parses one valid local rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-console {
        \\  lang ts, tsx
        \\  match call_expression @call {
        \\    function: member_expression @member
        \\  }
        \\  where { text(@member) == "console.log" }
        \\  emit @call { message "Avoid console.log" }
        \\}
    , &diag);

    try std.testing.expectEqual(@as(usize, 1), file.rules.len);
    try std.testing.expectEqualStrings("no-console", file.rules[0].id);
    try std.testing.expectEqual(ast.RuleKind.local, file.rules[0].kind);
    try std.testing.expectEqual(@as(usize, 2), file.rules[0].languages.len);
    try std.testing.expectEqualStrings("ts", file.rules[0].languages[0]);
    try std.testing.expectEqualStrings("tsx", file.rules[0].languages[1]);
    try std.testing.expectEqual(ast.Severity.@"error", file.rules[0].severity);
    try std.testing.expectEqualStrings("call", file.rules[0].emit.capture.name);
    try std.testing.expectEqualStrings("Avoid console.log", file.rules[0].emit.message);

    const match = file.rules[0].match.?.node;
    try std.testing.expectEqualStrings("call_expression", match.node_kind.symbol);
    try std.testing.expectEqualStrings("call", match.capture.?.name);
    try std.testing.expectEqual(@as(usize, 1), match.fields.len);
    try expectFieldRelation("function", match.fields[0].relation);
    try std.testing.expectEqualStrings("member_expression", match.fields[0].pattern.node_kind.symbol);
    try std.testing.expectEqualStrings("member", match.fields[0].pattern.capture.?.name);

    const expression = file.rules[0].where[0].expression.compare;
    try std.testing.expectEqual(ast.CompareOp.eq, expression.op);
    try std.testing.expectEqualStrings("text", expression.left.*.call.name);
    try std.testing.expectEqualStrings("console.log", expression.right.*.string.value);
}

test "parser: parses multiple rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule first {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "first" }
        \\}
        \\rule second {
        \\  lang go
        \\  match identifier @id
        \\  emit @id { message "second" }
        \\}
    , &diag);

    try std.testing.expectEqual(@as(usize, 2), file.rules.len);
    try std.testing.expectEqualStrings("first", file.rules[0].id);
    try std.testing.expectEqualStrings("second", file.rules[1].id);
}

test "parser: rejects empty files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRule, parse(arena.allocator(), "", &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 1), diag.column);
}

test "parser: rejects unknown top level forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRule, parse(arena.allocator(), "lang ts", &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 1), diag.column);
}

test "parser: rejects unknown clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.UnknownClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  nope yes
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expectEqual(@as(u32, 3), diag.column);
}

test "parser: rejects duplicate singleton clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  lang tsx
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expectEqual(@as(u32, 3), diag.column);
}

test "parser: rejects missing required clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag_emit: parser.Diagnostic = .{};
    try std.testing.expectError(error.MissingEmit, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\}
    , &diag_emit));

    var diag_lang: parser.Diagnostic = .{};
    try std.testing.expectError(error.MissingLanguage, parse(arena.allocator(),
        \\rule bad {
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag_lang));

    var diag_match: parser.Diagnostic = .{};
    try std.testing.expectError(error.MissingMatch, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  emit @id { message "bad" }
        \\}
    , &diag_match));
}

test "parser: rejects malformed matcher fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedColon, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match call_expression @call {
        \\    function member_expression @member
        \\  }
        \\  emit @call { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 4), diag.line);
    try std.testing.expectEqual(@as(u32, 14), diag.column);
}

test "parser: decodes strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule escaped {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "a\\b\"c\nd\re\t" }
        \\}
    , &diag);

    try std.testing.expectEqualStrings("a\\b\"c\nd\re\t", file.rules[0].emit.message);
}

test "parser: parses optional clauses in any order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule configured {
        \\  severity warn
        \\  exclude paths "vendor/**", generated
        \\  match identifier @id
        \\  kind local
        \\  emit @id { message "configured" }
        \\  lang ts
        \\}
    , &diag);

    const rule = file.rules[0];
    try std.testing.expectEqual(ast.RuleKind.local, rule.kind);
    try std.testing.expectEqual(ast.Severity.warn, rule.severity);
    try std.testing.expectEqual(@as(usize, 2), rule.exclude_paths.len);
    try std.testing.expectEqualStrings("vendor/**", rule.exclude_paths[0]);
    try std.testing.expectEqualStrings("generated", rule.exclude_paths[1]);
}

test "parser: parses project rules without lang and match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule repository-isolation {
        \\  kind project
        \\  where { imports(@source) > 0 }
        \\  emit @source { message "Repository boundary violated" }
        \\}
    , &diag);

    const rule = file.rules[0];
    try std.testing.expectEqual(ast.RuleKind.project, rule.kind);
    try std.testing.expectEqual(@as(usize, 0), rule.languages.len);
    try std.testing.expectEqual(@as(?ast.Match, null), rule.match);
    try std.testing.expectEqual(@as(usize, 1), rule.where.len);
}

test "parser: parses match kind clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule function-too-long {
        \\  lang ts
        \\  match kind function @function
        \\  emit @function { message "Function too long" }
        \\}
    , &diag);

    const match = file.rules[0].match.?.kind;
    try std.testing.expectEqualStrings("function", match.kind);
    try std.testing.expectEqualStrings("function", match.capture.?.name);
}

test "parser: parses nested matcher fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule nested {
        \\  lang ts
        \\  match call_expression @call {
        \\    function: member_expression @member {
        \\      object: identifier @receiver
        \\    }
        \\  }
        \\  emit @call { message "nested" }
        \\}
    , &diag);

    const member = file.rules[0].match.?.node.fields[0].pattern;
    try std.testing.expectEqual(@as(usize, 1), member.fields.len);
    try expectFieldRelation("object", member.fields[0].relation);
    try std.testing.expectEqualStrings("identifier", member.fields[0].pattern.node_kind.symbol);
    try std.testing.expectEqualStrings("receiver", member.fields[0].pattern.capture.?.name);
}

test "parser: parses anonymous token matcher fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule logical-operator {
        \\  lang ts
        \\  match binary_expression @match {
        \\    operator: "&&"
        \\  }
        \\  emit @match { message "logical operator" }
        \\}
    , &diag);

    const operator = file.rules[0].match.?.node.fields[0];
    try expectFieldRelation("operator", operator.relation);
    try std.testing.expectEqualStrings("&&", operator.pattern.node_kind.anonymous);
}

test "parser: parses alternation matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule function-like {
        \\  lang ts
        \\  match [function_declaration, function_expression, arrow_function] @match
        \\  emit @match { message "function-like" }
        \\}
    , &diag);

    const kinds = file.rules[0].match.?.node.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 3), kinds.len);
    try std.testing.expectEqualStrings("function_declaration", kinds[0]);
    try std.testing.expectEqualStrings("function_expression", kinds[1]);
    try std.testing.expectEqualStrings("arrow_function", kinds[2]);
    try std.testing.expectEqualStrings("match", file.rules[0].match.?.node.capture.?.name);
}

test "parser: parses nested alternation matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule exits {
        \\  lang ts
        \\  match statement_block @body {
        \\    child: [return_statement, throw_statement] @exit
        \\  }
        \\  emit @body { message "exit" }
        \\}
    , &diag);

    const field = file.rules[0].match.?.node.fields[0];
    try std.testing.expectEqual(ast.PatternRelation.child, field.relation);
    const kinds = field.pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), kinds.len);
    try std.testing.expectEqualStrings("return_statement", kinds[0]);
    try std.testing.expectEqualStrings("throw_statement", kinds[1]);
    try std.testing.expectEqualStrings("exit", field.pattern.capture.?.name);
}

test "parser: parses positional children relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule positional {
        \\  lang ts
        \\  match statement_block @body {
        \\    child: expression_statement @first
        \\    children: return_statement @return
        \\  }
        \\  emit @body { message "positional" }
        \\}
    , &diag);

    const fields = file.rules[0].match.?.node.fields;
    try std.testing.expectEqual(ast.PatternRelation.child, fields[0].relation);
    try std.testing.expectEqual(ast.PatternRelation.children, fields[1].relation);
    try std.testing.expectEqualStrings("expression_statement", fields[0].pattern.node_kind.symbol);
    try std.testing.expectEqualStrings("return_statement", fields[1].pattern.node_kind.symbol);
}

test "parser: rejects top-level anonymous token matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedSymbol, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match "&&" @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects malformed alternation matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var empty_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedSymbol, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match [] @match
        \\  emit @match { message "bad" }
        \\}
    , &empty_diag));

    var comma_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightBracket, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match [identifier call_expression] @match
        \\  emit @match { message "bad" }
        \\}
    , &comma_diag));

    var close_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightBracket, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match [identifier, call_expression @match
        \\  emit @match { message "bad" }
        \\}
    , &close_diag));
}

test "parser: parses multiple predicates in one where block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule predicates {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    text(@id) != "allowed"
        \\    length(@id) >= 3
        \\  }
        \\  emit @id { message "predicate failed" }
        \\}
    , &diag);

    try std.testing.expectEqual(@as(usize, 2), file.rules[0].where.len);
    try std.testing.expectEqual(ast.CompareOp.ne, file.rules[0].where[0].expression.compare.op);
    try std.testing.expectEqual(ast.CompareOp.ge, file.rules[0].where[1].expression.compare.op);
}

test "parser: rejects duplicate where clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { text(@id) != "allowed" }
        \\  where { length(@id) >= 3 }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expectEqual(@as(u32, 3), diag.column);
}

test "parser: rejects empty where blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.EmptyWhere, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 4), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.column);
}

test "parser: parses logical precedence and negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule logic {
        \\  lang ts
        \\  match identifier @id
        \\  where { !capture(@ignored) || text(@id) == "a" && length(@id) < 10 }
        \\  emit @id { message "logic" }
        \\}
    , &diag);

    const expression = file.rules[0].where[0].expression.logical;
    try std.testing.expectEqual(ast.LogicalOp.@"or", expression.op);
    try std.testing.expectEqualStrings("capture", expression.left.*.negate.expression.*.call.name);
    try std.testing.expectEqual(ast.LogicalOp.@"and", expression.right.*.logical.op);
}

test "parser: parses parenthesized expressions and number literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule grouped {
        \\  lang ts
        \\  match identifier @id
        \\  where { (length(@id) <= 120) && args(@id) > 2 }
        \\  emit @id { message "grouped" }
        \\}
    , &diag);

    const expression = file.rules[0].where[0].expression.logical;
    try std.testing.expectEqual(ast.LogicalOp.@"and", expression.op);
    try std.testing.expectEqual(ast.CompareOp.le, expression.left.*.compare.op);
    try std.testing.expectEqual(@as(u32, 120), expression.left.*.compare.right.*.number.value);
    try std.testing.expectEqual(ast.CompareOp.gt, expression.right.*.compare.op);
    try std.testing.expectEqual(@as(u32, 2), expression.right.*.compare.right.*.number.value);
}

test "parser: parses rule ids with underscores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no_console {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "underscored" }
        \\}
    , &diag);

    try std.testing.expectEqualStrings("no_console", file.rules[0].id);
}

test "parser: rejects invalid rule ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var leading_dash: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRuleId, parse(arena.allocator(),
        \\rule -bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &leading_dash));

    var trailing_dash: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRuleId, parse(arena.allocator(),
        \\rule bad- {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &trailing_dash));
}

test "parser: rejects invalid kind and severity values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var kind_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidKind, parse(arena.allocator(),
        \\rule bad {
        \\  kind global
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &kind_diag));

    var severity_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidSeverity, parse(arena.allocator(),
        \\rule bad {
        \\  severity info
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &severity_diag));
}

test "parser: rejects duplicate match emit severity kind and exclude clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var match_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  match identifier @other
        \\  emit @id { message "bad" }
        \\}
    , &match_diag));

    var emit_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\  emit @id { message "bad" }
        \\}
    , &emit_diag));

    var severity_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  severity warn
        \\  severity error
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &severity_diag));

    var kind_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  kind local
        \\  kind project
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &kind_diag));

    var exclude_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  exclude paths vendor
        \\  exclude paths generated
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &exclude_diag));
}

test "parser: rejects malformed rule and emit blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var rule_brace_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedLeftBrace, parse(arena.allocator(), "rule bad lang ts", &rule_brace_diag));

    var emit_capture_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedCapture, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit id { message "bad" }
        \\}
    , &emit_capture_diag));

    var emit_message_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedMessage, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { title "bad" }
        \\}
    , &emit_message_diag));

    var emit_string_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedString, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message bad }
        \\}
    , &emit_string_diag));
}

test "parser: rejects unclosed blocks and expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var rule_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightBrace, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
    , &rule_diag));

    var matcher_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightBrace, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match call_expression @call {
        \\    function: identifier @id
    , &matcher_diag));

    var misplaced_clause_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedColon, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match call_expression @call {
        \\    function: identifier @id
        \\  emit @call { message "bad" }
        \\}
    , &misplaced_clause_diag));

    var paren_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightParen, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { text(@id == "bad" }
        \\  emit @id { message "bad" }
        \\}
    , &paren_diag));
}

test "parser: rejects invalid expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bare_symbol_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidExpression, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { text }
        \\  emit @id { message "bad" }
        \\}
    , &bare_symbol_diag));

    var missing_rhs_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidExpression, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { text(@id) == }
        \\  emit @id { message "bad" }
        \\}
    , &missing_rhs_diag));
}

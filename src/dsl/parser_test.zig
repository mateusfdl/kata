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
    try std.testing.expectEqual(ast.Maturity.stable, file.rules[0].maturity);
    try std.testing.expectEqual(@as(usize, 0), file.rules[0].former_ids.len);
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
        \\  maturity experimental
        \\  former-ids legacy-name
        \\  kind local
        \\  emit @id { message "configured" }
        \\  lang ts
        \\}
    , &diag);

    const rule = file.rules[0];
    try std.testing.expectEqual(ast.RuleKind.local, rule.kind);
    try std.testing.expectEqual(ast.Severity.warn, rule.severity);
    try std.testing.expectEqual(ast.Maturity.experimental, rule.maturity);
    try std.testing.expectEqual(@as(usize, 1), rule.former_ids.len);
    try std.testing.expectEqualStrings("legacy-name", rule.former_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), rule.exclude_paths.len);
    try std.testing.expectEqualStrings("vendor/**", rule.exclude_paths[0]);
    try std.testing.expectEqualStrings("generated", rule.exclude_paths[1]);
}

test "parser: parses maturity clause values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { line: []const u8, expected: ast.Maturity }{
        .{ .line = "maturity experimental", .expected = .experimental },
        .{ .line = "maturity stable", .expected = .stable },
        .{ .line = "maturity deprecated", .expected = .deprecated },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(arena.allocator(),
            \\rule lifecycle {{
            \\  {s}
            \\  lang ts
            \\  match identifier @id
            \\  emit @id {{ message "lifecycle" }}
            \\}}
        , .{case.line});
        var diag: parser.Diagnostic = .{};
        const file = try parse(arena.allocator(), source, &diag);
        try std.testing.expectEqual(case.expected, file.rules[0].maturity);
    }
}

test "parser: parses former-ids clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule renamed {
        \\  former-ids old-name, "other-old"
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "renamed" }
        \\}
    , &diag);

    const rule = file.rules[0];
    try std.testing.expectEqual(@as(usize, 2), rule.former_ids.len);
    try std.testing.expectEqualStrings("old-name", rule.former_ids[0]);
    try std.testing.expectEqualStrings("other-old", rule.former_ids[1]);
}

test "parser: rejects invalid former-ids items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var trailing_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRuleId, parse(arena.allocator(),
        \\rule bad {
        \\  former-ids old-
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &trailing_diag));

    var leading_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRuleId, parse(arena.allocator(),
        \\rule bad {
        \\  former-ids "-old"
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &leading_diag));

    var empty_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRuleId, parse(arena.allocator(),
        \\rule bad {
        \\  former-ids ""
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &empty_diag));
}

test "parser: rejects duplicate former-ids clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  former-ids old-a
        \\  former-ids old-b
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects invalid maturity value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidMaturity, parse(arena.allocator(),
        \\rule bad {
        \\  maturity bogus
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects duplicate maturity clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  maturity experimental
        \\  maturity stable
        \\  lang ts
        \\  match identifier @id
        \\  emit @id { message "bad" }
        \\}
    , &diag));
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

    const branches = file.rules[0].match.?.node.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 3), branches.len);
    try std.testing.expectEqualStrings("function_declaration", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("function_expression", branches[1].node_kind.symbol);
    try std.testing.expectEqualStrings("arrow_function", branches[2].node_kind.symbol);
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
    const branches = field.pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("return_statement", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("throw_statement", branches[1].node_kind.symbol);
    try std.testing.expectEqualStrings("exit", field.pattern.capture.?.name);
}

test "parser: expands pattern fragments at the match root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\pattern callable = [function_declaration, method_declaration]
        \\rule uses-fragment {
        \\  lang go
        \\  match $callable @match {
        \\    body: block
        \\  }
        \\  emit @match { message "callable" }
        \\}
    , &diag);

    const node = file.rules[0].match.?.node;
    try std.testing.expectEqualStrings("match", node.capture.?.name);
    const branches = node.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("function_declaration", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("method_declaration", branches[1].node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 1), node.fields.len);
    try expectFieldRelation("body", node.fields[0].relation);
}

test "parser: expands pattern fragments in field position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\pattern repoReceiver = [type_identifier @recv, pointer_type { child: type_identifier @recv }]
        \\rule repo-rule {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: parameter_list {
        \\      child: parameter_declaration {
        \\        type: $repoReceiver
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "repo" }
        \\}
    , &diag);

    const receiver = file.rules[0].match.?.node.fields[0].pattern;
    const param = receiver.fields[0].pattern;
    const branches = param.fields[0].pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("recv", branches[0].capture.?.name);
    try std.testing.expectEqualStrings("pointer_type", branches[1].node_kind.symbol);
}

test "parser: fragments reference earlier fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\pattern namedType = type_identifier @recv
        \\pattern receiverType = [$namedType, pointer_type { child: $namedType }]
        \\rule repo-rule {
        \\  lang go
        \\  match parameter_declaration @match {
        \\    type: $receiverType
        \\  }
        \\  emit @match { message "repo" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.fields[0].pattern.node_kind.alternation;
    try std.testing.expectEqualStrings("type_identifier", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("recv", branches[0].capture.?.name);
    try std.testing.expectEqualStrings("recv", branches[1].fields[0].pattern.capture.?.name);
}

test "parser: rejects unknown fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.UnknownFragment, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match $nope @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects duplicate fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateFragment, parse(arena.allocator(),
        \\pattern callable = function_declaration
        \\pattern callable = method_declaration
        \\rule bad {
        \\  lang go
        \\  match $callable @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects unused fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.UnusedFragment, parse(arena.allocator(),
        \\pattern callable = function_declaration
        \\rule bad {
        \\  lang go
        \\  match method_declaration @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects capture conflicts on fragment references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.FragmentCaptureConflict, parse(arena.allocator(),
        \\pattern named = function_declaration @fn
        \\rule bad {
        \\  lang go
        \\  match $named @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects anonymous-rooted fragments at the match root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedSymbol, parse(arena.allocator(),
        \\pattern voidOp = "void"
        \\rule bad {
        \\  lang ts
        \\  match $voidOp @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: parses negated field assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-return-type {
        \\  lang go
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\    !result
        \\  }
        \\  emit @match { message "no return type" }
        \\}
    , &diag);

    const node = file.rules[0].match.?.node;
    try std.testing.expectEqual(@as(usize, 1), node.fields.len);
    try std.testing.expectEqual(@as(usize, 1), node.absent_fields.len);
    try std.testing.expectEqualStrings("result", node.absent_fields[0]);
}

test "parser: parses negated fields inside alternation branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-return-type {
        \\  lang go
        \\  match [function_declaration { !result }, method_declaration { !result }] @match
        \\  emit @match { message "no return type" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.node_kind.alternation;
    try std.testing.expectEqualStrings("result", branches[0].absent_fields[0]);
    try std.testing.expectEqualStrings("result", branches[1].absent_fields[0]);
}

test "parser: parses negated fields in nested matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule has-untyped {
        \\  lang go
        \\  match source_file @match
        \\  where {
        \\    has @match function_declaration { !result }
        \\  }
        \\  emit @match { message "has an untyped function" }
        \\}
    , &diag);

    const matcher = file.rules[0].where[0].composition.matcher;
    try std.testing.expectEqual(@as(usize, 1), matcher.pattern.absent_fields.len);
    try std.testing.expectEqualStrings("result", matcher.pattern.absent_fields[0]);
}

test "parser: rejects negated pseudo-relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var child_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidNegatedField, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match function_declaration @match { !child }
        \\  emit @match { message "bad" }
        \\}
    , &child_diag));

    var children_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidNegatedField, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match function_declaration @match { !children }
        \\  emit @match { message "bad" }
        \\}
    , &children_diag));
}

test "parser: parses subtree alternation branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule repo-receiver {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: [type_identifier @recv, pointer_type { child: type_identifier @recv }]
        \\  }
        \\  emit @match { message "repo receiver" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.fields[0].pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("type_identifier", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("recv", branches[0].capture.?.name);
    try std.testing.expectEqual(@as(usize, 0), branches[0].fields.len);
    try std.testing.expectEqualStrings("pointer_type", branches[1].node_kind.symbol);
    try std.testing.expectEqual(@as(?ast.Capture, null), branches[1].capture);
    try std.testing.expectEqual(ast.PatternRelation.child, branches[1].fields[0].relation);
    try std.testing.expectEqualStrings("type_identifier", branches[1].fields[0].pattern.node_kind.symbol);
    try std.testing.expectEqualStrings("recv", branches[1].fields[0].pattern.capture.?.name);
}

test "parser: parses anonymous alternation branches in field position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-unary-keywords {
        \\  lang ts
        \\  match unary_expression @match {
        \\    operator: ["void", "delete"]
        \\  }
        \\  emit @match { message "unary keyword" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.fields[0].pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("void", branches[0].node_kind.anonymous);
    try std.testing.expectEqualStrings("delete", branches[1].node_kind.anonymous);
}

test "parser: tolerates trailing commas in alternation matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule function-like {
        \\  lang go
        \\  match [
        \\    function_declaration,
        \\    method_declaration,
        \\  ] @match
        \\  emit @match { message "function-like" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("function_declaration", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("method_declaration", branches[1].node_kind.symbol);
}

test "parser: parses nested alternation branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule indirect-type {
        \\  lang go
        \\  match parameter_declaration @match {
        \\    type: [type_identifier, [pointer_type, slice_type]]
        \\  }
        \\  emit @match { message "indirect type" }
        \\}
    , &diag);

    const branches = file.rules[0].match.?.node.fields[0].pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("type_identifier", branches[0].node_kind.symbol);
    const inner = branches[1].node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), inner.len);
    try std.testing.expectEqualStrings("pointer_type", inner[0].node_kind.symbol);
    try std.testing.expectEqualStrings("slice_type", inner[1].node_kind.symbol);
}

test "parser: rejects anonymous alternation branches at match root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedSymbol, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match [identifier, "&&"] @match
        \\  emit @match { message "bad" }
        \\}
    , &diag));
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

test "parser: parses bare symbol call arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule repository-isolation {
        \\  kind project
        \\  where { endsWith(field(@call, receiver), "Repository") }
        \\  emit @call { message "repositories can only be called by repositories" }
        \\}
    , &diag);

    const call = file.rules[0].where[0].expression.call;
    try std.testing.expectEqualStrings("endsWith", call.name);
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    const field = call.args[0].call;
    try std.testing.expectEqualStrings("field", field.name);
    try std.testing.expectEqualStrings("call", field.args[0].capture.name);
    try std.testing.expectEqualStrings("receiver", field.args[1].symbol.name);
    try std.testing.expectEqualStrings("Repository", call.args[1].string.value);
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

test "parser: parses inside composition with a nested where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-console-outside-logger {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    not inside @match class_declaration {
        \\      name: type_identifier @class_name
        \\      where {
        \\        text(@class_name) == "Logger"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "console is only allowed inside Logger" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.inside, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqualStrings("match", composition.matcher.subject.name);
    try std.testing.expectEqualStrings("class_declaration", composition.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 1), composition.matcher.pattern.fields.len);
    try expectFieldRelation("name", composition.matcher.pattern.fields[0].relation);
    try std.testing.expectEqualStrings("class_name", composition.matcher.pattern.fields[0].pattern.capture.?.name);
    try std.testing.expectEqual(@as(usize, 1), composition.matcher.where.len);
    const nested = composition.matcher.where[0].compare;
    try std.testing.expectEqual(ast.CompareOp.eq, nested.op);
    try std.testing.expectEqualStrings("Logger", nested.right.*.string.value);
}

test "parser: parses any groups of composition predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule contextual {
        \\  lang go
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    any {
        \\      inside @match if_statement
        \\      inside @match for_statement
        \\    }
        \\  }
        \\  emit @match { message "contextual" }
        \\}
    , &diag);

    const group = file.rules[0].where[0].group;
    try std.testing.expectEqual(ast.GroupOp.any, group.op);
    try std.testing.expectEqual(@as(usize, 2), group.predicates.len);
    try std.testing.expectEqual(ast.CompositionOp.inside, group.predicates[0].composition.op);
    try std.testing.expectEqual(ast.CompositionOp.inside, group.predicates[1].composition.op);
    try std.testing.expectEqualStrings("if_statement", group.predicates[0].composition.matcher.pattern.node_kind.symbol);
}

test "parser: parses all groups nested inside any" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule contextual {
        \\  lang go
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    any {
        \\      all {
        \\        inside @match if_statement
        \\        text(@fn) == "panic"
        \\      }
        \\      text(@fn) == "log"
        \\    }
        \\  }
        \\  emit @match { message "contextual" }
        \\}
    , &diag);

    const group = file.rules[0].where[0].group;
    try std.testing.expectEqual(ast.GroupOp.any, group.op);
    try std.testing.expectEqual(@as(usize, 2), group.predicates.len);
    const inner = group.predicates[0].group;
    try std.testing.expectEqual(ast.GroupOp.all, inner.op);
    try std.testing.expectEqual(@as(usize, 2), inner.predicates.len);
    try std.testing.expectEqual(ast.CompositionOp.inside, inner.predicates[0].composition.op);
    try std.testing.expectEqual(ast.CompareOp.eq, inner.predicates[1].expression.compare.op);
    try std.testing.expectEqual(ast.CompareOp.eq, group.predicates[1].expression.compare.op);
}

test "parser: rejects empty predicate groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.EmptyWhere, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match call_expression @match
        \\  where {
        \\    any { }
        \\  }
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: parses has with an alternation matcher" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-empty-catch {
        \\  lang ts
        \\  match catch_clause @match {
        \\    body: statement_block @body
        \\  }
        \\  where {
        \\    not has @body [throw_statement, call_expression]
        \\  }
        \\  emit @match { message "catch block must handle or rethrow the error" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.has, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqualStrings("body", composition.matcher.subject.name);
    const branches = composition.matcher.pattern.node_kind.alternation;
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("throw_statement", branches[0].node_kind.symbol);
    try std.testing.expectEqualStrings("call_expression", branches[1].node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 0), composition.matcher.where.len);
}

test "parser: parses has without negation alongside expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule has-panic {
        \\  lang go
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\  }
        \\  where {
        \\    text(@name) == "process"
        \\    has @match call_expression {
        \\      function: identifier @fn
        \\      where {
        \\        text(@fn) == "panic"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "process must not panic" }
        \\}
    , &diag);

    try std.testing.expectEqual(@as(usize, 2), file.rules[0].where.len);
    try std.testing.expectEqual(ast.CompareOp.eq, file.rules[0].where[0].expression.compare.op);
    const composition = file.rules[0].where[1].composition;
    try std.testing.expectEqual(ast.CompositionOp.has, composition.op);
    try std.testing.expectEqual(false, composition.negated);
    try std.testing.expectEqualStrings("panic", composition.matcher.where[0].compare.right.*.string.value);
}

test "parser: parses not parent composition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-void {
        \\  lang ts
        \\  match unary_expression @match {
        \\    operator: "void"
        \\  }
        \\  where {
        \\    not parent @match expression_statement
        \\  }
        \\  emit @match { message "void is not allowed" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.parent, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqualStrings("match", composition.matcher.subject.name);
    try std.testing.expectEqualStrings("expression_statement", composition.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 0), composition.matcher.pattern.fields.len);
}

test "parser: parses inside composition with an until boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-defer-in-loop {
        \\  lang go
        \\  match defer_statement @match
        \\  where {
        \\    inside @match for_statement until func_literal
        \\  }
        \\  emit @match { message "defer in loop" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.inside, composition.op);
    try std.testing.expectEqual(false, composition.negated);
    try std.testing.expectEqualStrings("for_statement", composition.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 1), composition.until.len);
    try std.testing.expectEqualStrings("func_literal", composition.until[0]);
}

test "parser: parses not inside with multiple until boundary kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule boundary-pair {
        \\  lang go
        \\  match defer_statement @match
        \\  where {
        \\    not inside @match for_statement until func_literal, method_declaration
        \\  }
        \\  emit @match { message "boundary pair" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.inside, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqual(@as(usize, 2), composition.until.len);
    try std.testing.expectEqualStrings("func_literal", composition.until[0]);
    try std.testing.expectEqualStrings("method_declaration", composition.until[1]);
}

test "parser: parses follows composition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule lock-then-unlock {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows @match expression_statement
        \\  }
        \\  emit @match { message "lock then unlock" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.follows, composition.op);
    try std.testing.expectEqual(false, composition.negated);
    try std.testing.expectEqualStrings("match", composition.matcher.subject.name);
    try std.testing.expectEqualStrings("expression_statement", composition.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 0), composition.until.len);
}

test "parser: parses precedes composition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule defer-after-open {
        \\  lang go
        \\  match defer_statement @match
        \\  where {
        \\    precedes @match short_var_declaration
        \\  }
        \\  emit @match { message "defer after open" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.precedes, composition.op);
    try std.testing.expectEqual(false, composition.negated);
    try std.testing.expectEqualStrings("short_var_declaration", composition.matcher.pattern.node_kind.symbol);
}

test "parser: parses negated follows and precedes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule sequenced {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    not follows @match return_statement
        \\    not precedes @match return_statement
        \\  }
        \\  emit @match { message "sequenced" }
        \\}
    , &diag);

    const follows = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.follows, follows.op);
    try std.testing.expectEqual(true, follows.negated);
    const precedes = file.rules[0].where[1].composition;
    try std.testing.expectEqual(ast.CompositionOp.precedes, precedes.op);
    try std.testing.expectEqual(true, precedes.negated);
}

test "parser: parses follows with a nested capture and where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule unlock-follows-lock {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    not follows @match expression_statement {
        \\      child: call_expression {
        \\        function: selector_expression {
        \\          field: field_identifier @unlock
        \\        }
        \\      }
        \\      where {
        \\        text(@unlock) in ["Unlock", "RUnlock"]
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "lock without unlock" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.follows, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqualStrings("expression_statement", composition.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(@as(usize, 1), composition.matcher.pattern.fields.len);
    try std.testing.expectEqual(@as(usize, 1), composition.matcher.where.len);
    const membership = composition.matcher.where[0].membership;
    try std.testing.expectEqual(false, membership.negated);
    try std.testing.expectEqual(@as(usize, 2), membership.values.len);
    try std.testing.expectEqualStrings("Unlock", membership.values[0].value);
}

test "parser: parses follows inside an any group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule sequenced {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    any {
        \\      follows @match return_statement
        \\      precedes @match return_statement
        \\    }
        \\  }
        \\  emit @match { message "sequenced" }
        \\}
    , &diag);

    const group = file.rules[0].where[0].group;
    try std.testing.expectEqual(ast.GroupOp.any, group.op);
    try std.testing.expectEqual(@as(usize, 2), group.predicates.len);
    try std.testing.expectEqual(ast.CompositionOp.follows, group.predicates[0].composition.op);
    try std.testing.expectEqual(ast.CompositionOp.precedes, group.predicates[1].composition.op);
}

test "parser: rejects until on follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.InvalidExpression, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows @match return_statement until func_literal
        \\  }
        \\  emit @match { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expectEqual(@as(u32, 37), diag.column);
}

test "parser: rejects follows inside a nested where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.NestedComposition, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    has @match call_expression {
        \\      where {
        \\        follows @match return_statement
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 7), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.column);
}

test "parser: rejects follows without a subject capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedCapture, parse(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows return_statement
        \\  }
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: parses in membership with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-weak-assertions {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      property: property_identifier @name
        \\    }
        \\  }
        \\  where {
        \\    text(@name) in [
        \\      "toBeNull",
        \\      "toBeTruthy",
        \\    ]
        \\  }
        \\  emit @match { message "weak assertion" }
        \\}
    , &diag);

    const membership = file.rules[0].where[0].expression.membership;
    try std.testing.expectEqual(false, membership.negated);
    try std.testing.expectEqualStrings("text", membership.subject.*.call.name);
    try std.testing.expectEqual(@as(usize, 2), membership.values.len);
    try std.testing.expectEqualStrings("toBeNull", membership.values[0].value);
    try std.testing.expectEqualStrings("toBeTruthy", membership.values[1].value);
}

test "parser: parses not in membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule allowlist {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    text(@name) not in ["toEqual", "toStrictEqual"]
        \\  }
        \\  emit @match { message "not allowlisted" }
        \\}
    , &diag);

    const membership = file.rules[0].where[0].expression.membership;
    try std.testing.expectEqual(true, membership.negated);
    try std.testing.expectEqual(@as(usize, 2), membership.values.len);
    try std.testing.expectEqualStrings("toEqual", membership.values[0].value);
}

test "parser: rejects an empty set literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.EmptySetLiteral, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    text(@name) in []
        \\  }
        \\  emit @match { message "bad" }
        \\}
    , &diag));
}

test "parser: parses count with a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule too-many-returns {
        \\  lang ts
        \\  match function_declaration @match
        \\  where {
        \\    count @match return_statement > 3
        \\  }
        \\  emit @match { message "function has too many return statements" }
        \\}
    , &diag);

    const count = file.rules[0].where[0].count;
    try std.testing.expectEqualStrings("match", count.matcher.subject.name);
    try std.testing.expectEqualStrings("return_statement", count.matcher.pattern.node_kind.symbol);
    try std.testing.expectEqual(ast.CompareOp.gt, count.op);
    try std.testing.expectEqual(@as(u32, 3), count.value);
}

test "parser: rejects not without inside or has" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedComposition, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    not count @id return_statement > 3
        \\  }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.column);
}

test "parser: rejects count without a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedComparison, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    count @id return_statement
        \\  }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 6), diag.line);
    try std.testing.expectEqual(@as(u32, 3), diag.column);
}

test "parser: rejects composition inside a nested where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.NestedComposition, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    inside @id class_declaration {
        \\      where {
        \\        has @id return_statement
        \\      }
        \\    }
        \\  }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
    try std.testing.expectEqual(@as(u32, 7), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.column);
}

test "parser: rejects duplicate nested where clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    inside @id class_declaration {
        \\      where { text(@id) == "a" }
        \\      where { text(@id) == "b" }
        \\    }
        \\  }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects fields after a nested where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedRightBrace, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    inside @id class_declaration {
        \\      where { text(@id) == "a" }
        \\      name: type_identifier @name
        \\    }
        \\  }
        \\  emit @id { message "bad" }
        \\}
    , &diag));
}

test "parser: parses a fix clause with the default target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule prefer-number-parseint {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "Prefer Number.parseInt"
        \\    fix safe "Number.parseInt"
        \\  }
        \\}
    , &diag);

    const fix = file.rules[0].emit.fix.?;
    try std.testing.expectEqual(ast.FixSafety.safe, fix.safety);
    try std.testing.expectEqual(@as(?ast.Capture, null), fix.target);
    try std.testing.expectEqualStrings("Number.parseInt", fix.template);
    try std.testing.expectEqual(@as(usize, 0), file.rules[0].emit.suggestions.len);
}

test "parser: parses an unsafe fix targeting another capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule bad-cast {
        \\  lang ts
        \\  match as_expression @match {
        \\    child: predefined_type @t
        \\  }
        \\  emit @match {
        \\    message "bad cast"
        \\    fix unsafe @t "unknown"
        \\  }
        \\}
    , &diag);

    const fix = file.rules[0].emit.fix.?;
    try std.testing.expectEqual(ast.FixSafety.unsafe, fix.safety);
    try std.testing.expectEqualStrings("t", fix.target.?.name);
    try std.testing.expectEqualStrings("unknown", fix.template);
}

test "parser: parses repeated suggestions preserving order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-any {
        \\  lang ts
        \\  match identifier @id {
        \\    child: predefined_type @t
        \\  }
        \\  emit @id {
        \\    message "no any"
        \\    suggest "use unknown" @t "unknown"
        \\    suggest "keep it" "{text(@id)}"
        \\  }
        \\}
    , &diag);

    const suggestions = file.rules[0].emit.suggestions;
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("use unknown", suggestions[0].label);
    try std.testing.expectEqualStrings("t", suggestions[0].target.?.name);
    try std.testing.expectEqualStrings("unknown", suggestions[0].template);
    try std.testing.expectEqualStrings("keep it", suggestions[1].label);
    try std.testing.expectEqual(@as(?ast.Capture, null), suggestions[1].target);
    try std.testing.expectEqualStrings("{text(@id)}", suggestions[1].template);
    try std.testing.expectEqual(@as(?ast.Fix, null), file.rules[0].emit.fix);
}

test "parser: parses an empty fix template as a deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-thing {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "remove it"
        \\    fix safe ""
        \\  }
        \\}
    , &diag);

    try std.testing.expectEqualStrings("", file.rules[0].emit.fix.?.template);
}

test "parser: rejects malformed fix and suggest clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var safety_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedSafety, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "bad"
        \\    fix "Number.parseInt"
        \\  }
        \\}
    , &safety_diag));

    var duplicate_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.DuplicateFix, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "bad"
        \\    fix safe "a"
        \\    fix safe "b"
        \\  }
        \\}
    , &duplicate_diag));

    var order_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedMessage, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    fix safe "a"
        \\    message "bad"
        \\  }
        \\}
    , &order_diag));

    var template_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedString, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "bad"
        \\    fix safe
        \\  }
        \\}
    , &template_diag));

    var label_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedString, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "bad"
        \\    suggest @id "unknown"
        \\  }
        \\}
    , &label_diag));

    var clause_diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.UnknownClause, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  emit @id {
        \\    message "bad"
        \\    title "extra"
        \\  }
        \\}
    , &clause_diag));
}

test "parser: parses between composition with two subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule no-await-in-transaction {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\    child: expression_statement @commit
        \\  }
        \\  where {
        \\    not between @begin @commit expression_statement
        \\  }
        \\  emit @block { message "no await between begin and commit" }
        \\}
    , &diag);

    const composition = file.rules[0].where[0].composition;
    try std.testing.expectEqual(ast.CompositionOp.between, composition.op);
    try std.testing.expectEqual(true, composition.negated);
    try std.testing.expectEqualStrings("begin", composition.matcher.subject.name);
    try std.testing.expectEqualStrings("commit", composition.second.?.name);
    try std.testing.expectEqualStrings("expression_statement", composition.matcher.pattern.node_kind.symbol);
}

test "parser: parses between inside an any group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule bracketed {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\    child: expression_statement @commit
        \\  }
        \\  where {
        \\    any {
        \\      between @begin @commit return_statement
        \\      between @begin @commit throw_statement
        \\    }
        \\  }
        \\  emit @block { message "bracketed" }
        \\}
    , &diag);

    const group = file.rules[0].where[0].group;
    try std.testing.expectEqual(@as(usize, 2), group.predicates.len);
    try std.testing.expectEqual(ast.CompositionOp.between, group.predicates[0].composition.op);
    try std.testing.expectEqualStrings("commit", group.predicates[0].composition.second.?.name);
}

test "parser: leaves second subject unset for follows and precedes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    const file = try parse(arena.allocator(),
        \\rule sequenced {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows @match return_statement
        \\  }
        \\  emit @match { message "sequenced" }
        \\}
    , &diag);

    try std.testing.expectEqual(@as(?ast.Capture, null), file.rules[0].where[0].composition.second);
}

test "parser: rejects between with a single subject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.ExpectedCapture, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\  }
        \\  where {
        \\    between @begin expression_statement
        \\  }
        \\  emit @block { message "bad" }
        \\}
    , &diag));
}

test "parser: rejects between inside a nested where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag: parser.Diagnostic = .{};
    try std.testing.expectError(error.NestedComposition, parse(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\    child: expression_statement @commit
        \\  }
        \\  where {
        \\    has @block call_expression {
        \\      where {
        \\        between @begin @commit expression_statement
        \\      }
        \\    }
        \\  }
        \\  emit @block { message "bad" }
        \\}
    , &diag));
}

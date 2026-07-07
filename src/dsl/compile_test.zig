const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const compile = @import("compile.zig");
const dsl_parser = @import("parser.zig");

const diagnostic = @import("../lint/diagnostic.zig");
const engine = @import("../lint/Engine.zig");
const expr = @import("../lint/expr.zig");
const language = @import("../lint/language.zig");
const rule = @import("../lint/rule.zig");

fn parseDsl(arena: std.mem.Allocator, source: []const u8) !ast.File {
    var diag: dsl_parser.Diagnostic = .{};
    var p = try dsl_parser.Parser.init(arena, source, &diag);
    return p.parseFile();
}

fn compileDsl(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    lang: language.Name,
    source: []const u8,
) !rule.CompiledRule {
    const file = try parseDsl(arena, source);
    var diag: rule.Diagnostic = .{};
    return compile.compile(gpa, lang, file, &diag);
}

fn predicateArgs(predicate: rule.Predicate) []const rule.PredicateOperand {
    return switch (predicate) {
        .eq, .not_eq, .any_of, .not_any_of, .starts_with, .not_starts_with, .ends_with, .not_ends_with, .contains, .not_contains, .glob, .not_glob, .captured, .not_captured => |args| args,
        .match, .not_match => |p| p.args,
        .has, .not_has, .inside, .not_inside, .parent, .not_parent => |p| p.args,
        .count => |p| p.args,
        .where => unreachable,
    };
}

fn regexPredicate(predicate: rule.Predicate) rule.RegexPredicate {
    return switch (predicate) {
        .match, .not_match => |p| p,
        else => unreachable,
    };
}

fn nestedPredicate(predicate: rule.Predicate) rule.NestedPredicate {
    return switch (predicate) {
        .has, .not_has, .inside, .not_inside, .parent, .not_parent => |p| p,
        else => unreachable,
    };
}

fn countPredicate(predicate: rule.Predicate) rule.CountPredicate {
    return switch (predicate) {
        .count => |p| p,
        else => unreachable,
    };
}

fn wherePredicate(predicate: rule.Predicate) *const expr.Expr {
    return switch (predicate) {
        .where => |p| p,
        else => unreachable,
    };
}

fn runCompiled(
    gpa: std.mem.Allocator,
    compiled: *const rule.CompiledRule,
    lang: language.Name,
    source: []const u8,
    path: ?[]const u8,
) ![]diagnostic.Diagnostic {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language.grammar(lang));
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    errdefer out.deinit(gpa);
    try engine.runRule(gpa, compiled, cursor, .{ .source = source, .root = tree.rootNode() }, lang, path, &out);
    return out.toOwnedSlice(gpa);
}

const kata_no_console =
    \\rule no-console {
    \\  lang ts
    \\  match call_expression @match {
    \\    function: member_expression {
    \\      object: identifier @receiver
    \\    }
    \\  }
    \\  where { text(@receiver) == "console" }
    \\  emit @match { message "console is not allowed" }
    \\}
;

const scm_no_console =
    \\((call_expression
    \\  function: (member_expression
    \\    object: (identifier) @receiver)) @match
    \\ (#eq? @receiver "console")
    \\ (#set! message "console is not allowed"))
;

test "compile: dsl no-console matches scm diagnostics" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var kata_compiled = try compileDsl(gpa, arena.allocator(), .ts, kata_no_console);
    defer kata_compiled.deinit();

    var scm_diag: rule.Diagnostic = .{};
    var scm_compiled = try rule.compile(gpa, .ts, &.{.{
        .id = "no-console",
        .source = scm_no_console,
    }}, &scm_diag);
    defer scm_compiled.deinit();

    const source = "console.log(\"x\");\nfoo.bar(1);\n";
    const kata_diags = try runCompiled(gpa, &kata_compiled, .ts, source, null);
    defer gpa.free(kata_diags);
    const scm_diags = try runCompiled(gpa, &scm_compiled, .ts, source, null);
    defer gpa.free(scm_diags);

    try std.testing.expectEqual(@as(usize, 1), scm_diags.len);
    try std.testing.expectEqualDeep(scm_diags, kata_diags);
}

test "compile: emits from a non-match capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-console {
        \\  lang ts
        \\  match call_expression @call {
        \\    function: member_expression {
        \\      object: identifier @receiver
        \\      property: property_identifier @method
        \\    }
        \\  }
        \\  where { text(@receiver) == "console" }
        \\  emit @method { message "console is not allowed" }
        \\}
    );
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &compiled, .ts, "console.log(1);\n", null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 8), diags[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 11), diags[0].range.end.column);
}

test "compile: translates string predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule strict-logging {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @receiver
        \\      property: property_identifier @method
        \\    }
        \\  }
        \\  where {
        \\    text(@receiver) != "logger"
        \\    matches(text(@method), "^log")
        \\    !matches(text(@method), "^debug")
        \\  }
        \\  emit @match { message "bad logging call" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 3), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_eq, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.match, std.meta.activeTag(predicates[1]));
    try std.testing.expectEqual(rule.PredicateOp.not_match, std.meta.activeTag(predicates[2]));
    _ = regexPredicate(predicates[1]);
    _ = regexPredicate(predicates[2]);
    try std.testing.expectEqualStrings("logger", predicateArgs(predicates[0])[1].string);
}

test "compile: translates numeric measures to where expressions" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule max-complexity {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { complexity(@match) > 10 || nesting(@match) > 3 }
        \\  emit @match { message "too complex" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.where, std.meta.activeTag(predicates[0]));
    const where_expr = wherePredicate(predicates[0]);
    try std.testing.expectEqual(@as(usize, 2), where_expr.any.len);
    try std.testing.expectEqual(@as(u32, 10), where_expr.any[0].compare.right.number);
    try std.testing.expectEqual(@as(u32, 3), where_expr.any[1].compare.right.number);
    try std.testing.expect(compiled.needs_measures);
}

test "compile: builds message segments from call placeholders" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule max-complexity {
        \\  lang ts
        \\  match function_declaration @match
        \\  where { complexity(@match) > 10 }
        \\  emit @match { message "complexity {complexity(@match)} exceeds 10" }
        \\}
    );
    defer compiled.deinit();

    const segments = compiled.patterns[0].message.?.segments;
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("complexity ", segments[0].literal);
    try std.testing.expectEqual(.complexity, segments[1].placeholder.measure);
    try std.testing.expectEqualStrings(" exceeds 10", segments[2].literal);
}

test "compile: applies severity and exclude paths" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-console {
        \\  lang ts
        \\  severity warn
        \\  exclude paths "vendor/**"
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @receiver
        \\    }
        \\  }
        \\  where { text(@receiver) == "console" }
        \\  emit @match { message "no console" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(diagnostic.Severity.warn, compiled.patterns[0].severity);

    const excluded = try runCompiled(gpa, &compiled, .ts, "console.log(1);\n", "vendor/x.ts");
    defer gpa.free(excluded);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);

    const included = try runCompiled(gpa, &compiled, .ts, "console.log(1);\n", "src/x.ts");
    defer gpa.free(included);
    try std.testing.expectEqual(@as(usize, 1), included.len);
}

test "compile: matches anonymous operator tokens" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-logical-and {
        \\  lang ts
        \\  match binary_expression @match {
        \\    operator: "&&"
        \\  }
        \\  emit @match { message "no &&" }
        \\}
    );
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &compiled, .ts, "const x = a && b;\nconst y = a || b;\n", null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
}

test "compile: matches alternation node kinds" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-boolean-literal {
        \\  lang ts
        \\  match [true, false] @match
        \\  emit @match { message "no boolean literal" }
        \\}
    );
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &compiled, .ts, "const x = true;\nconst y = 1;\n", null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
}

test "compile: distributes field patterns over alternation branches" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule ctx-first {
        \\  lang go
        \\  match [function_declaration, method_declaration] {
        \\    parameters: parameter_list {
        \\      child: parameter_declaration
        \\      child: parameter_declaration @match {
        \\        type: qualified_type {
        \\          package: package_identifier @pkg
        \\          name: type_identifier @typ
        \\        }
        \\      }
        \\    }
        \\  }
        \\  where {
        \\    text(@pkg) == "context"
        \\    text(@typ) == "Context"
        \\  }
        \\  emit @match { message "context must come first" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "import \"context\"\n\n" ++
        "func bad(id string, ctx context.Context) error { return nil }\n\n" ++
        "func (s Svc) alsoBad(id string, ctx context.Context) error { return nil }\n\n" ++
        "func clean(ctx context.Context) (Result, context.Context, error) { return Result{}, ctx, nil }\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("context must come first", diags[0].message);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 6), diags[1].range.start.line);
}

test "compile: distributes fields over an alternation inside a field pattern" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule block-bodied-value {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    value: [arrow_function, function_expression] {
        \\      body: statement_block @body
        \\    }
        \\  }
        \\  emit @match { message "function value" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "const f = () => { return 1; };\n" ++
        "const g = function () { return 2; };\n" ++
        "const h = () => 3;\n" ++
        "const i = 4;\n";
    const diags = try runCompiled(gpa, &compiled, .ts, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
}

test "compile: nested matchers accept alternations with fields" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule has-function {
        \\  lang go
        \\  match source_file @match
        \\  where {
        \\    has @match [function_declaration, func_literal] {
        \\      body: block @body
        \\    }
        \\  }
        \\  emit @match { message "has a function" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.has, std.meta.activeTag(predicates[0]));
    try std.testing.expect(std.meta.activeTag(predicates[0]) == .has or std.meta.activeTag(predicates[0]) == .count);
    try std.testing.expectEqual(@as(usize, 1), compiled.nested_queries.len);
}

test "compile: skips project rules and other languages" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule go-only {
        \\  lang go
        \\  match call_expression @match
        \\  emit @match { message "go" }
        \\}
        \\rule project-wide {
        \\  kind project
        \\  where { text(@import) == "x" }
        \\  emit @import { message "project" }
        \\}
        \\rule ts-only {
        \\  lang ts
        \\  match call_expression @match
        \\  emit @match { message "ts" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.patterns.len);
    try std.testing.expectEqualStrings("ts-only", compiled.patterns[0].rule_id);
}

test "compile: rejects invalid rules" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const cases = [_]struct { err: anyerror, source: []const u8 }{
        .{ .err = error.UnknownLanguage, .source =
        \\rule bad {
        \\  lang python
        \\  match call_expression @match
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.UnsupportedMatch, .source =
        \\rule bad {
        \\  lang ts
        \\  match kind function @match
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.UnknownCapture, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match
        \\  emit @nope { message "bad" }
        \\}
        },
        .{ .err = error.EmitCaptureConflict, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  emit @name { message "bad" }
        \\}
        },
        .{ .err = error.UnknownCapture, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match
        \\  where { text(@ghost) == "x" }
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.InvalidStringComparison, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where { text(@fn) > "a" }
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.UnknownMeasure, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match
        \\  where { junk(@match) > 3 }
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.UnsupportedPredicate, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @a
        \\      property: property_identifier @b
        \\    }
        \\  }
        \\  where { text(@a) == "x" || text(@b) == "y" }
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.QueryCompileFailed, .source =
        \\rule bad {
        \\  lang ts
        \\  match not_a_real_node_kind @match
        \\  emit @match { message "bad" }
        \\}
        },
        .{ .err = error.UnsupportedPlaceholder, .source =
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match
        \\  emit @match { message "value {junk(@match)}" }
        \\}
        },
    };

    for (cases) |case| {
        try std.testing.expectError(case.err, compileDsl(gpa, arena.allocator(), .ts, case.source));
    }
}

test "compile: folds string disjunctions into any-of" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-weak-assertions {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      property: property_identifier @name
        \\    }
        \\  }
        \\  where {
        \\    text(@name) == "toBeDefined" || text(@name) == "toBeNull" || text(@name) == "toBeTruthy"
        \\  }
        \\  emit @match { message "weak assertion" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 4), predicateArgs(predicates[0]).len);
    try std.testing.expectEqualStrings("toBeDefined", predicateArgs(predicates[0])[1].string);
    try std.testing.expectEqualStrings("toBeNull", predicateArgs(predicates[0])[2].string);
    try std.testing.expectEqualStrings("toBeTruthy", predicateArgs(predicates[0])[3].string);
}

test "compile: negated string disjunction becomes not-any-of" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule allowlist {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    !(text(@name) == "info" || text(@name) == "warn")
        \\  }
        \\  emit @match { message "not allowlisted" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 3), predicateArgs(predicates[0]).len);
}

test "compile: anyOf helper lowers to the any-of predicate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-weak-assertions {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      property: property_identifier @name
        \\    }
        \\  }
        \\  where {
        \\    anyOf(text(@name), "toBeDefined", "toBeNull", "toBeTruthy")
        \\  }
        \\  emit @match { message "weak assertion" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 4), predicateArgs(predicates[0]).len);
    try std.testing.expectEqualStrings("toBeDefined", predicateArgs(predicates[0])[1].string);
    try std.testing.expectEqualStrings("toBeNull", predicateArgs(predicates[0])[2].string);
    try std.testing.expectEqualStrings("toBeTruthy", predicateArgs(predicates[0])[3].string);
}

test "compile: noneOf helper lowers to the not-any-of predicate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule allowlist {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    noneOf(text(@name), "info", "warn")
        \\  }
        \\  emit @match { message "not allowlisted" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 3), predicateArgs(predicates[0]).len);
}

test "compile: in operator lowers to the any-of predicate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-weak-assertions {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      property: property_identifier @name
        \\    }
        \\  }
        \\  where {
        \\    text(@name) in ["toBeDefined", "toBeNull", "toBeTruthy"]
        \\  }
        \\  emit @match { message "weak assertion" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 4), predicateArgs(predicates[0]).len);
    try std.testing.expectEqualStrings("toBeDefined", predicateArgs(predicates[0])[1].string);
    try std.testing.expectEqualStrings("toBeNull", predicateArgs(predicates[0])[2].string);
    try std.testing.expectEqualStrings("toBeTruthy", predicateArgs(predicates[0])[3].string);
}

test "compile: not in operator lowers to the not-any-of predicate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule allowlist {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    text(@name) not in ["info", "warn"]
        \\  }
        \\  emit @match { message "not allowlisted" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_any_of, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(@as(usize, 3), predicateArgs(predicates[0]).len);
}

test "compile: negated in operator lowers to not-any-of" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule allowlist {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    !(text(@name) in ["info", "warn"])
        \\  }
        \\  emit @match { message "not allowlisted" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(rule.PredicateOp.not_any_of, std.meta.activeTag(predicates[0]));
}

test "compile: anyOf without any values is rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const got = compileDsl(gpa, arena.allocator(), .ts,
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @name
        \\  }
        \\  where {
        \\    anyOf(text(@name))
        \\  }
        \\  emit @match { message "bad" }
        \\}
    );
    try std.testing.expectError(error.UnsupportedPredicate, got);
}

test "compile: disjunction across different captures is unsupported" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const got = compileDsl(gpa, arena.allocator(), .ts,
        \\rule mixed {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: member_expression {
        \\      object: identifier @obj
        \\      property: property_identifier @name
        \\    }
        \\  }
        \\  where {
        \\    text(@obj) == "console" || text(@name) == "log"
        \\  }
        \\  emit @match { message "mixed" }
        \\}
    );

    try std.testing.expectError(error.UnsupportedPredicate, got);
}

test "compile: translates has composition to a nested matcher" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule has-panic {
        \\  lang go
        \\  match function_declaration @match
        \\  where {
        \\    has @match call_expression {
        \\      function: identifier @fn
        \\      where {
        \\        text(@fn) == "panic"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "function panics" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.has, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expect(nested.root_capture_id != rule.invalid_capture_id);
    try std.testing.expectEqual(@as(usize, 1), nested.predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.eq, std.meta.activeTag(nested.predicates[0]));
    try std.testing.expectEqualStrings("panic", predicateArgs(nested.predicates[0])[1].string);
    try std.testing.expectEqual(@as(usize, 1), compiled.nested_queries.len);
    try std.testing.expect(!compiled.needs_measures);
}

test "compile: reuses a bound nested root capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule outside-logger {
        \\  lang ts
        \\  match call_expression @match
        \\  where {
        \\    not inside @match class_declaration @cls {
        \\      name: type_identifier @name
        \\      where {
        \\        text(@name) == "Logger"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "only inside Logger" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(rule.PredicateOp.not_inside, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expectEqual(rule.captureIdForName(nested.query, "cls"), nested.root_capture_id);
}

test "compile: translates not parent composition to a nested matcher" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
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
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_parent, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expect(nested.root_capture_id != rule.invalid_capture_id);
    try std.testing.expectEqual(@as(usize, 1), compiled.nested_queries.len);
    try std.testing.expect(!compiled.needs_measures);
}

test "compile: translates count with a comparison" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule too-many-returns {
        \\  lang ts
        \\  match function_declaration @match
        \\  where {
        \\    count @match return_statement > 3
        \\  }
        \\  emit @match { message "too many returns" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(rule.PredicateOp.count, std.meta.activeTag(predicates[0]));
    try std.testing.expect(std.meta.activeTag(predicates[0]) == .has or std.meta.activeTag(predicates[0]) == .count);
    try std.testing.expectEqual(expr.Compare.gt, countPredicate(predicates[0]).compare.op);
    try std.testing.expectEqual(@as(u32, 3), countPredicate(predicates[0]).compare.value);
}

test "compile: unknown subject capture in composition fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    has @nope return_statement
        \\  }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnknownCapture, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("unknown capture", diag.detail);
}

test "compile: invalid node kind in a nested matcher fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    has @id not_a_real_node_kind
        \\  }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.QueryCompileFailed, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("node kind or field is invalid for the grammar", diag.detail);
}

test "compile: reserved nested root capture fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where {
        \\    has @id return_statement @kata-nested-root
        \\  }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.ReservedCapture, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("kata-nested-root is a reserved capture", diag.detail);
}

test "compile: measures in a nested where set needs_measures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule complex-methods {
        \\  lang ts
        \\  match class_declaration @match
        \\  where {
        \\    has @match method_definition @method {
        \\      where {
        \\        complexity(@method) > 5
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "class has a complex method" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expect(compiled.needs_measures);
}

test "compile: translates string helper predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule hook-names {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    startsWith(text(@fn), "use")
        \\    !endsWith(text(@fn), "Deprecated")
        \\    contains(text(@fn), "Effect")
        \\    !contains(text(@fn), "Legacy")
        \\  }
        \\  emit @match { message "bad hook name" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 4), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.starts_with, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.not_ends_with, std.meta.activeTag(predicates[1]));
    try std.testing.expectEqual(rule.PredicateOp.contains, std.meta.activeTag(predicates[2]));
    try std.testing.expectEqual(rule.PredicateOp.not_contains, std.meta.activeTag(predicates[3]));
    try std.testing.expectEqualStrings("use", predicateArgs(predicates[0])[1].string);
    try std.testing.expectEqualStrings("Deprecated", predicateArgs(predicates[1])[1].string);
    try std.testing.expectEqualStrings("Effect", predicateArgs(predicates[2])[1].string);
    try std.testing.expectEqualStrings("Legacy", predicateArgs(predicates[3])[1].string);
}

test "compile: string helpers require two text arguments" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { startsWith(text(@id)) }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("startsWith, endsWith, and contains expect (value, text)", diag.detail);
}

test "compile: translates glob predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-internal-imports {
        \\  lang ts
        \\  match import_statement @match {
        \\    source: string {
        \\      child: string_fragment @src
        \\    }
        \\  }
        \\  where {
        \\    glob(text(@src), "**/internal/**")
        \\    !glob(text(@src), "**/public/**")
        \\  }
        \\  emit @match { message "internal import" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 2), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.glob, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.not_glob, std.meta.activeTag(predicates[1]));
    try std.testing.expectEqualStrings("**/internal/**", predicateArgs(predicates[0])[1].string);
    try std.testing.expectEqualStrings("**/public/**", predicateArgs(predicates[1])[1].string);
}

test "compile: glob requires a string literal pattern" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { glob(text(@id), text(@id)) }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("glob expects (value, \"pattern\")", diag.detail);
}

test "compile: translates capture presence predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule has-returns {
        \\  lang ts
        \\  match function_declaration @match {
        \\    body: statement_block {
        \\      children: return_statement @rets
        \\    }
        \\  }
        \\  where {
        \\    capture(@rets)
        \\    !capture(@rets)
        \\  }
        \\  emit @match { message "impossible" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].predicates;
    try std.testing.expectEqual(@as(usize, 2), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.captured, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.not_captured, std.meta.activeTag(predicates[1]));
}

test "compile: capture predicate requires one capture argument" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { capture("id") }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("capture expects one capture argument", diag.detail);
}

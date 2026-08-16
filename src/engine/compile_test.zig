const std = @import("std");

const ast = @import("dsl").ast;
const compile = @import("dsl").compile;
const dsl_parser = @import("dsl").parser;

const diagnostic = @import("engine").diagnostic;
const engine = @import("engine");
const expr = @import("engine").expr;
const language = @import("engine").language;
const rule = @import("engine").rule;
const test_tree = @import("engine").test_tree;

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
    var compiled = try compile.compile(gpa, lang, file, &diag);
    compiled.dispatch = try engine.dispatch.Table.build(
        compiled.arena.allocator(),
        gpa,
        compiled.patterns,
        engine.family.of(lang.family()).kind_count,
    );
    return compiled;
}

fn predicateArgs(predicate: rule.Predicate) []const rule.PredicateOperand {
    return switch (predicate) {
        .eq, .not_eq, .any_of, .not_any_of, .starts_with, .not_starts_with, .ends_with, .not_ends_with, .contains, .not_contains, .glob, .not_glob, .captured, .not_captured => |args| args,
        .match, .not_match => |p| p.args,
        .has, .not_has, .inside, .not_inside, .parent, .not_parent, .follows, .not_follows, .precedes, .not_precedes, .between, .not_between => |p| p.args,
        .count => |p| p.args,
        .where, .any_group, .all_group => unreachable,
    };
}

fn groupMembers(predicate: rule.Predicate) []const rule.Predicate {
    return switch (predicate) {
        .any_group, .all_group => |members| members,
        else => unreachable,
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
        .has, .not_has, .inside, .not_inside, .parent, .not_parent, .follows, .not_follows, .precedes, .not_precedes, .between, .not_between => |p| p,
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
    var t = test_tree.build(gpa, lang, source);
    defer t.deinit(gpa);

    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    errdefer out.deinit(gpa);
    try engine.runRule(gpa, compiled, .{
        .allocator = gpa,
        .source = source,
        .root = t.root(),
    }, lang, &.{}, path, &out);
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

test "compile: dsl no-console produces one diagnostic" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var kata_compiled = try compileDsl(gpa, arena.allocator(), .ts, kata_no_console);
    defer kata_compiled.deinit();

    const source = "console.log(\"x\");\nfoo.bar(1);\n";
    const kata_diags = try runCompiled(gpa, &kata_compiled, .ts, source, null);
    defer gpa.free(kata_diags);

    try std.testing.expectEqual(@as(usize, 1), kata_diags.len);
    try std.testing.expectEqualStrings("no-console", kata_diags[0].rule_id);
    try std.testing.expectEqualStrings("console is not allowed", kata_diags[0].message);
    try std.testing.expectEqual(@as(u32, 0), kata_diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), kata_diags[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 16), kata_diags[0].range.end.column);
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.where, std.meta.activeTag(predicates[0]));
    const where_expr = wherePredicate(predicates[0]);
    try std.testing.expectEqual(@as(usize, 2), where_expr.any.len);
    try std.testing.expectEqual(@as(u32, 10), where_expr.any[0].compare.right.number);
    try std.testing.expectEqual(@as(u32, 3), where_expr.any[1].compare.right.number);
    try std.testing.expect(compiled.needs_measures);
}

test "compile: text compared with a number is a numeric measure" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule short-timeouts {
        \\  lang ts
        \\  match variable_declarator @match {
        \\    value: number @n
        \\  }
        \\  where { text(@n) > 30000 }
        \\  emit @match { message "too long" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.where, std.meta.activeTag(predicates[0]));
    const where_expr = wherePredicate(predicates[0]);
    try std.testing.expectEqual(expr.Measure.text, where_expr.compare.left.measure.measure);
    try std.testing.expectEqual(@as(u32, 30000), where_expr.compare.right.number);
    try std.testing.expect(compiled.needs_measures);
}

test "compile: rejects a half-string comparison without numeric interpretation" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match call_expression @match
        \\  where { complexity(@match) > "high" }
        \\  emit @match { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};

    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqual(language.Name.ts, diag.lang.?);
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("unsupported where expression", diag.detail);
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

    const segments = compiled.patterns[0].meta.message.?.segments;
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
        \\  maturity deprecated
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

    try std.testing.expectEqual(diagnostic.Severity.warn, compiled.patterns[0].meta.severity);
    try std.testing.expectEqual(diagnostic.Maturity.deprecated, compiled.patterns[0].meta.maturity);

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

test "compile: matches a supertype across its concrete member kinds" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-declaration {
        \\  lang ts
        \\  match declaration @match
        \\  emit @match { message "no declaration" }
        \\}
    );
    defer compiled.deinit();

    const source = "class C {}\nconst x = 1;\nfunction f() {}\nx + 1;\n";
    const diags = try runCompiled(gpa, &compiled, .ts, source, null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 3), diags.len);
    try std.testing.expectEqual(@as(u32, 0), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 1), diags[1].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), diags[2].range.start.line);
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
    const diags = try runCompiled(arena.allocator(), &compiled, .go, src, null);
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

test "compile: fragments expand into working rules" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\pattern repoReceiver = [type_identifier @recv, pointer_type { child: type_identifier @recv }]
        \\rule repo-receiver {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: parameter_list {
        \\      child: parameter_declaration {
        \\        type: $repoReceiver
        \\      }
        \\    }
        \\  }
        \\  where { matches(text(@recv), "Repository$") }
        \\  emit @match { message "repo method" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "type UserRepository struct{}\n\n" ++
        "func (r UserRepository) FindValue(id string) string { return id }\n\n" ++
        "func (r *UserRepository) FindPointer(id string) string { return id }\n\n" ++
        "type OrderService struct{}\n\n" ++
        "func (s *OrderService) Create(id string) string { return id }\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 6), diags[1].range.start.line);
}

test "compile: fragments shared across rule blocks in one file" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\pattern callable = [function_declaration, method_declaration]
        \\rule no-untyped-callables {
        \\  lang go
        \\  match $callable @match {
        \\    !result
        \\  }
        \\  emit @match { message "callable has no result" }
        \\}
        \\rule no-callable-bodies {
        \\  lang go
        \\  match $callable @match {
        \\    body: block @body
        \\  }
        \\  where { length(@body) > 3 }
        \\  emit @match { message "callable body too long" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 2), compiled.patterns.len);

    const src =
        "package main\n\n" ++
        "func untyped() {}\n\n" ++
        "func typed() int { return 1 }\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("callable has no result", diags[0].message);
}

test "compile: negated fields match nodes lacking the field" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule no-return-type {
        \\  lang go
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\    !result
        \\  }
        \\  emit @match { message "function has no result" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "func typed() int { return 1 }\n\n" ++
        "func untyped() {}\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
}

test "compile: distributes negated fields over alternation branches" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule no-return-type {
        \\  lang go
        \\  match [function_declaration, method_declaration] @match {
        \\    !result
        \\  }
        \\  emit @match { message "callable has no result" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "type Svc struct{}\n\n" ++
        "func typed() int { return 1 }\n\n" ++
        "func untyped() {}\n\n" ++
        "func (s Svc) Typed() int { return 1 }\n\n" ++
        "func (s Svc) Untyped() {}\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 6), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 10), diags[1].range.start.line);
}

test "compile: negated fields work in nested matchers" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule has-untyped-function {
        \\  lang go
        \\  match source_file @match
        \\  where {
        \\    has @match function_declaration { !result }
        \\  }
        \\  emit @match { message "file has an untyped function" }
        \\}
    );
    defer compiled.deinit();

    const with_untyped = "package main\n\nfunc untyped() {}\n";
    const flagged = try runCompiled(gpa, &compiled, .go, with_untyped, null);
    defer gpa.free(flagged);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);

    const all_typed = "package main\n\nfunc typed() int { return 1 }\n";
    const clean = try runCompiled(gpa, &compiled, .go, all_typed, null);
    defer gpa.free(clean);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "compile: rejects invalid negated field names" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match function_declaration @match { !not_a_field }
        \\  emit @match { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.QueryCompileFailed, compile.compile(gpa, .go, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("node kind or field is invalid for the grammar", diag.detail);
}

test "compile: rejects negated fields on anonymous tokens" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match binary_expression @match {
        \\    operator: "&&" { !left }
        \\  }
        \\  emit @match { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedMatch, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("anonymous tokens cannot have child patterns", diag.detail);
}

test "compile: subtree alternation branches bind captures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule repo-receiver {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: parameter_list {
        \\      child: parameter_declaration {
        \\        type: [type_identifier @recv, pointer_type { child: type_identifier @recv }]
        \\      }
        \\    }
        \\  }
        \\  where { matches(text(@recv), "Repository$") }
        \\  emit @match { message "method on {text(@recv)}" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "type UserRepository struct{}\n\n" ++
        "func (r UserRepository) FindValue(id string) string { return id }\n\n" ++
        "func (r *UserRepository) FindPointer(id string) string { return id }\n\n" ++
        "type OrderService struct{}\n\n" ++
        "func (s *OrderService) Create(id string) string { return id }\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    defer for (diags) |d| gpa.free(d.message);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("method on UserRepository", diags[0].message);
    try std.testing.expectEqualStrings("method on UserRepository", diags[1].message);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 6), diags[1].range.start.line);
}

test "compile: distributes shared fields after branch fields" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule named-callable {
        \\  lang go
        \\  match [
        \\    function_declaration { name: identifier @name },
        \\    method_declaration { name: field_identifier @name },
        \\  ] @match {
        \\    body: block
        \\  }
        \\  where { startsWith(text(@name), "Handle") }
        \\  emit @match { message "callable {text(@name)}" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "func HandleUser() {}\n\n" ++
        "func ignored() {}\n\n" ++
        "type Svc struct{}\n\n" ++
        "func (s Svc) HandleOrder() {}\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    defer for (diags) |d| gpa.free(d.message);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqualStrings("callable HandleUser", diags[0].message);
    try std.testing.expectEqualStrings("callable HandleOrder", diags[1].message);
}

test "compile: matches anonymous alternation branches" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-logical-operators {
        \\  lang ts
        \\  match binary_expression @match {
        \\    operator: ["&&", "||"]
        \\  }
        \\  emit @match { message "no logical operators" }
        \\}
    );
    defer compiled.deinit();

    const src = "const x = a && b;\nconst y = a || b;\nconst z = a + b;\n";
    const diags = try runCompiled(gpa, &compiled, .ts, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
}

test "compile: partial branch captures fail predicates closed" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule pointer-repo-receiver {
        \\  lang go
        \\  match method_declaration @match {
        \\    receiver: parameter_list {
        \\      child: parameter_declaration {
        \\        type: [type_identifier, pointer_type { child: type_identifier @inner }]
        \\      }
        \\    }
        \\  }
        \\  where { matches(text(@inner), "Repository$") }
        \\  emit @match { message "pointer repo receiver" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "type UserRepository struct{}\n\n" ++
        "func (r UserRepository) FindValue(id string) string { return id }\n\n" ++
        "func (r *UserRepository) FindPointer(id string) string { return id }\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 6), diags[0].range.start.line);
}

test "compile: rejects an emit capture missing from an alternation branch" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match parameter_declaration {
        \\    type: [type_identifier @match, pointer_type { child: type_identifier }]
        \\  }
        \\  emit @match { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.EmitCaptureMissingInBranch, compile.compile(gpa, .go, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("emit capture must be bound in every alternation branch", diag.detail);
}

test "compile: nested matchers accept subtree alternation branches" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule returns-literal {
        \\  lang go
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\  }
        \\  where {
        \\    has @match [return_statement { child: expression_list }, go_statement]
        \\  }
        \\  emit @match { message "returns or spawns" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "func withReturn() int { return 1 }\n\n" ++
        "func withGo() { go withReturn() }\n\n" ++
        "func bare() {}\n";
    const diags = try runCompiled(gpa, &compiled, .go, src, null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
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

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.has, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expect(nested.root_capture_id < nested.capture_count);
}

test "compile: any groups lower to any_group predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule contextual-panic {
        \\  lang go
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    text(@fn) == "panic"
        \\    any {
        \\      inside @match if_statement
        \\      inside @match for_statement
        \\    }
        \\  }
        \\  emit @match { message "contextual panic" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 2), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.eq, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.any_group, std.meta.activeTag(predicates[1]));
    const members = groupMembers(predicates[1]);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(rule.PredicateOp.inside, std.meta.activeTag(members[0]));
    try std.testing.expectEqual(rule.PredicateOp.inside, std.meta.activeTag(members[1]));
}

test "compile: conjunction members stay atomic inside any groups" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule paired-names {
        \\  lang go
        \\  match binary_expression @match {
        \\    left: identifier @left
        \\    right: identifier @right
        \\  }
        \\  where {
        \\    any {
        \\      text(@left) == "a" && text(@right) == "b"
        \\      text(@left) == "c"
        \\    }
        \\  }
        \\  emit @match { message "paired names" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    const members = groupMembers(predicates[0]);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(rule.PredicateOp.all_group, std.meta.activeTag(members[0]));
    try std.testing.expectEqual(@as(usize, 2), groupMembers(members[0]).len);
    try std.testing.expectEqual(rule.PredicateOp.eq, std.meta.activeTag(members[1]));
}

test "compile: any group matches when either composition holds" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule contextual-panic {
        \\  lang go
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  where {
        \\    text(@fn) == "panic"
        \\    any {
        \\      inside @match if_statement
        \\      inside @match for_statement
        \\    }
        \\  }
        \\  emit @match { message "contextual panic" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "func a(x bool) {\n" ++
        "\tif x {\n" ++
        "\t\tpanic(\"in if\")\n" ++
        "\t}\n" ++
        "\tfor {\n" ++
        "\t\tpanic(\"in for\")\n" ++
        "\t}\n" ++
        "\tpanic(\"bare\")\n" ++
        "}\n";
    const diags = try runCompiled(arena.allocator(), &compiled, .go, src, null);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 7), diags[1].range.start.line);
}

test "compile: all groups nested in any evaluate as conjunctions" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule guarded-calls {
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
        \\      text(@fn) == "recover"
        \\    }
        \\  }
        \\  emit @match { message "guarded call" }
        \\}
    );
    defer compiled.deinit();

    const src =
        "package main\n\n" ++
        "func a(x bool) {\n" ++
        "\tif x {\n" ++
        "\t\tpanic(\"guarded\")\n" ++
        "\t}\n" ++
        "\tpanic(\"bare\")\n" ++
        "\trecover()\n" ++
        "}\n";
    const diags = try runCompiled(arena.allocator(), &compiled, .go, src, null);
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 4), diags[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 7), diags[1].range.start.line);
}

test "compile: measures inside groups set needs_measures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule complex-or-named {
        \\  lang go
        \\  match function_declaration @match {
        \\    name: identifier @name
        \\  }
        \\  where {
        \\    any {
        \\      complexity(@match) > 5
        \\      text(@name) == "legacy"
        \\    }
        \\  }
        \\  emit @match { message "complex or named" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(true, compiled.needs_measures);
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
    try std.testing.expectEqualStrings("ts-only", compiled.patterns[0].meta.rule_id);
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.has, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expect(nested.root_capture_id < nested.capture_count);
    try std.testing.expectEqual(@as(usize, 1), nested.predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.eq, std.meta.activeTag(nested.predicates[0]));
    try std.testing.expectEqualStrings("panic", predicateArgs(nested.predicates[0])[1].string);
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

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(rule.PredicateOp.not_inside, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expectEqual(nested.pattern.capture.?, nested.root_capture_id);
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

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_parent, std.meta.activeTag(predicates[0]));
    const nested = nestedPredicate(predicates[0]).matcher;
    try std.testing.expect(nested.root_capture_id < nested.capture_count);
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

    const predicates = compiled.patterns[0].meta.predicates;
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

test "compile: dialect specific kind compiles for ts and matches nothing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const jsx_rule =
        \\rule no-jsx {
        \\  lang ts
        \\  match jsx_element @match
        \\  emit @match { message "no jsx" }
        \\}
    ;
    var compiled = try compileDsl(gpa, arena.allocator(), .ts, jsx_rule);
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &compiled, .ts, "const a = 1;\n", null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "compile: builds a fix with the default target" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule prefer-number-parseint {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match {
        \\    message "Prefer Number.parseInt"
        \\    fix safe "Number.parseInt"
        \\  }
        \\}
    );
    defer compiled.deinit();

    const fix = compiled.patterns[0].meta.fix.?;
    try std.testing.expectEqual(diagnostic.Safety.safe, fix.safety);
    try std.testing.expectEqual(compiled.patterns[0].match_capture_id.?, fix.target_id);
    try std.testing.expectEqualStrings("Number.parseInt", fix.template.plain);
    try std.testing.expectEqual(@as(usize, 0), compiled.patterns[0].meta.suggestions.len);
}

test "compile: builds an unsafe fix targeting another capture with segments" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule wrap-call {
        \\  lang ts
        \\  match call_expression @match {
        \\    function: identifier @fn
        \\  }
        \\  emit @match {
        \\    message "wrap it"
        \\    fix unsafe @fn "wrap({text(@fn)})"
        \\  }
        \\}
    );
    defer compiled.deinit();

    const fix = compiled.patterns[0].meta.fix.?;
    try std.testing.expectEqual(diagnostic.Safety.unsafe, fix.safety);
    try std.testing.expect(fix.target_id != compiled.patterns[0].match_capture_id.?);
    const segments = fix.template.segments;
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("wrap(", segments[0].literal);
    try std.testing.expectEqual(expr.Measure.text, segments[1].placeholder.measure);
    try std.testing.expectEqualStrings(")", segments[2].literal);
    try std.testing.expectEqual(true, compiled.needs_measures);
}

test "compile: builds suggestions in order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-any {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match {
        \\    message "no any"
        \\    suggest "use unknown" "unknown"
        \\    suggest "delete it" ""
        \\  }
        \\}
    );
    defer compiled.deinit();

    const suggestions = compiled.patterns[0].meta.suggestions;
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("use unknown", suggestions[0].label);
    try std.testing.expectEqualStrings("unknown", suggestions[0].template.plain);
    try std.testing.expectEqual(compiled.patterns[0].match_capture_id.?, suggestions[0].target_id);
    try std.testing.expectEqualStrings("delete it", suggestions[1].label);
    try std.testing.expectEqualStrings("", suggestions[1].template.plain);
    try std.testing.expectEqual(false, compiled.patterns[0].meta.fix != null);
}

test "compile: rejects a fix target missing from an alternation branch" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match parameter_declaration @match {
        \\    type: [type_identifier @t, pointer_type { child: type_identifier }]
        \\  }
        \\  emit @match {
        \\    message "bad"
        \\    fix safe @t "x"
        \\  }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.FixCaptureMissingInBranch, compile.compile(gpa, .go, file, &diag));
    try std.testing.expectEqualStrings("fix capture must be bound in every alternation branch", diag.detail);
}

test "compile: rejects a fix template capture missing from an alternation branch" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match parameter_declaration @match {
        \\    type: [type_identifier @t, pointer_type { child: type_identifier }]
        \\  }
        \\  emit @match {
        \\    message "bad"
        \\    suggest "swap" "{text(@t)}"
        \\  }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.FixCaptureMissingInBranch, compile.compile(gpa, .go, file, &diag));
    try std.testing.expectEqualStrings("fix capture must be bound in every alternation branch", diag.detail);
}

test "compile: rejects an unknown fix target" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match {
        \\    message "bad"
        \\    fix safe @ghost "x"
        \\  }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnknownCapture, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("fix capture not found in match", diag.detail);
}

test "compile: needs measures when only the fix template interpolates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule echo {
        \\  lang ts
        \\  match identifier @match
        \\  emit @match {
        \\    message "plain"
        \\    fix safe "{text(@match)}"
        \\  }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(true, compiled.needs_measures);
}

test "compile: translates follows and precedes to nested matchers" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule sequenced {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    not follows @match expression_statement
        \\    precedes @match return_statement
        \\  }
        \\  emit @match { message "sequenced" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 2), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_follows, std.meta.activeTag(predicates[0]));
    try std.testing.expectEqual(rule.PredicateOp.precedes, std.meta.activeTag(predicates[1]));

    const follows = nestedPredicate(predicates[0]);
    try std.testing.expectEqual(@as(usize, 1), follows.args.len);
    try std.testing.expectEqual(compiled.patterns[0].match_capture_id.?, follows.args[0].capture);
    try std.testing.expect(follows.matcher.root_capture_id < follows.matcher.capture_count);
    try std.testing.expectEqual(@as(usize, 0), follows.until_kinds.len);
    try std.testing.expect(!compiled.needs_measures);
}

test "compile: rejects follows with an unknown subject capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows @nope expression_statement
        \\  }
        \\  emit @match { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnknownCapture, compile.compile(gpa, .go, file, &diag));
    try std.testing.expectEqualStrings("unknown capture", diag.detail);
}

test "compile: measures in a follows nested where set needs_measures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule long-neighbour {
        \\  lang go
        \\  match expression_statement @match
        \\  where {
        \\    follows @match func_literal @fn {
        \\      where {
        \\        length(@fn) > 3
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "long neighbour" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(rule.PredicateOp.follows, std.meta.activeTag(compiled.patterns[0].meta.predicates[0]));
    try std.testing.expectEqual(true, compiled.needs_measures);
}

test "compile: follows filters diagnostics by later siblings" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .go,
        \\rule lock-without-unlock {
        \\  lang go
        \\  match expression_statement @match {
        \\    child: call_expression {
        \\      function: selector_expression {
        \\        field: field_identifier @method
        \\      }
        \\    }
        \\  }
        \\  where {
        \\    text(@method) == "Lock"
        \\    not follows @match expression_statement {
        \\      child: call_expression {
        \\        function: selector_expression {
        \\          field: field_identifier @unlock
        \\        }
        \\      }
        \\      where {
        \\        text(@unlock) == "Unlock"
        \\      }
        \\    }
        \\  }
        \\  emit @match { message "Lock without a following Unlock" }
        \\}
    );
    defer compiled.deinit();

    const guarded =
        \\package main
        \\func f() {
        \\    mu.Lock()
        \\    mu.Unlock()
        \\}
    ;
    const clean = try runCompiled(arena.allocator(), &compiled, .go, guarded, null);
    try std.testing.expectEqual(@as(usize, 0), clean.len);

    const leaked =
        \\package main
        \\func f() {
        \\    mu.Lock()
        \\    do()
        \\}
    ;
    const flagged = try runCompiled(arena.allocator(), &compiled, .go, leaked, null);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);
    try std.testing.expectEqualStrings("lock-without-unlock", flagged[0].rule_id);
    try std.testing.expectEqual(@as(u32, 2), flagged[0].range.start.line);
}

test "compile: translates between with both subject captures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule bracketed {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\    child: expression_statement @commit
        \\  }
        \\  where {
        \\    not between @begin @commit return_statement
        \\  }
        \\  emit @block { message "bracketed" }
        \\}
    );
    defer compiled.deinit();

    const predicates = compiled.patterns[0].meta.predicates;
    try std.testing.expectEqual(@as(usize, 1), predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.not_between, std.meta.activeTag(predicates[0]));

    const between = nestedPredicate(predicates[0]);
    try std.testing.expectEqual(@as(usize, 2), between.args.len);
    try std.testing.expect(between.args[0].capture != between.args[1].capture);
    try std.testing.expect(between.matcher.root_capture_id < between.matcher.capture_count);
    try std.testing.expect(!compiled.needs_measures);
}

test "compile: rejects between with an unknown second capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\  }
        \\  where {
        \\    between @begin @nope return_statement
        \\  }
        \\  emit @block { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnknownCapture, compile.compile(gpa, .ts, file, &diag));
    try std.testing.expectEqualStrings("unknown capture", diag.detail);
}

test "compile: measures in a between nested where set needs_measures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule long-interval {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin
        \\    child: expression_statement @commit
        \\  }
        \\  where {
        \\    between @begin @commit expression_statement @mid {
        \\      where {
        \\        length(@mid) > 3
        \\      }
        \\    }
        \\  }
        \\  emit @block { message "long interval" }
        \\}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(rule.PredicateOp.between, std.meta.activeTag(compiled.patterns[0].meta.predicates[0]));
    try std.testing.expectEqual(true, compiled.needs_measures);
}

test "compile: between filters diagnostics by what sits in the interval" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var compiled = try compileDsl(gpa, arena.allocator(), .ts,
        \\rule no-await-in-transaction {
        \\  lang ts
        \\  match statement_block @block {
        \\    child: expression_statement @begin {
        \\      child: call_expression {
        \\        function: member_expression {
        \\          property: property_identifier @open
        \\        }
        \\      }
        \\    }
        \\    child: expression_statement @commit {
        \\      child: call_expression {
        \\        function: member_expression {
        \\          property: property_identifier @close
        \\        }
        \\      }
        \\    }
        \\  }
        \\  where {
        \\    text(@open) == "begin"
        \\    text(@close) == "commit"
        \\    between @begin @commit expression_statement @mid {
        \\      child: await_expression
        \\    }
        \\  }
        \\  emit @block { message "no await between begin and commit" }
        \\}
    );
    defer compiled.deinit();

    const clean = try runCompiled(arena.allocator(), &compiled, .ts, "async function f(){ tx.begin(); work(); tx.commit(); }", null);
    try std.testing.expectEqual(@as(usize, 0), clean.len);

    const flagged = try runCompiled(arena.allocator(), &compiled, .ts, "async function f(){ tx.begin(); await work(); tx.commit(); }", null);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);
    try std.testing.expectEqualStrings("no-await-in-transaction", flagged[0].rule_id);

    const outside = try runCompiled(arena.allocator(), &compiled, .ts, "async function f(){ await work(); tx.begin(); tx.commit(); }", null);
    try std.testing.expectEqual(@as(usize, 0), outside.len);
}

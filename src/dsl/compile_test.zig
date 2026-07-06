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
    registry: *language.Registry,
    arena: std.mem.Allocator,
    lang: language.Name,
    source: []const u8,
) !rule.CompiledRule {
    const file = try parseDsl(arena, source);
    var diag: rule.Diagnostic = .{};
    return compile.compile(gpa, registry, lang, file, &diag);
}

fn runCompiled(
    gpa: std.mem.Allocator,
    registry: *language.Registry,
    compiled: *const rule.CompiledRule,
    lang: language.Name,
    source: []const u8,
    path: ?[]const u8,
) ![]diagnostic.Diagnostic {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(registry.get(lang));
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
    var registry: language.Registry = .init();

    var kata_compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts, kata_no_console);
    defer kata_compiled.deinit();

    var scm_diag: rule.Diagnostic = .{};
    var scm_compiled = try rule.compile(gpa, &registry, .ts, &.{.{
        .id = "no-console",
        .language = .ts,
        .source = scm_no_console,
    }}, &scm_diag);
    defer scm_compiled.deinit();

    const source = "console.log(\"x\");\nfoo.bar(1);\n";
    const kata_diags = try runCompiled(gpa, &registry, &kata_compiled, .ts, source, null);
    defer gpa.free(kata_diags);
    const scm_diags = try runCompiled(gpa, &registry, &scm_compiled, .ts, source, null);
    defer gpa.free(scm_diags);

    try std.testing.expectEqual(@as(usize, 1), scm_diags.len);
    try std.testing.expectEqualDeep(scm_diags, kata_diags);
}

test "compile: emits from a non-match capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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

    const diags = try runCompiled(gpa, &registry, &compiled, .ts, "console.log(1);\n", null);
    defer gpa.free(diags);

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(@as(u32, 8), diags[0].range.start.column);
    try std.testing.expectEqual(@as(u32, 11), diags[0].range.end.column);
}

test "compile: translates string predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.not_eq, predicates[0].op);
    try std.testing.expectEqual(rule.PredicateOp.match, predicates[1].op);
    try std.testing.expectEqual(rule.PredicateOp.not_match, predicates[2].op);
    try std.testing.expect(predicates[1].regex != null);
    try std.testing.expect(predicates[2].regex != null);
    try std.testing.expectEqualStrings("logger", predicates[0].args[1].string);
}

test "compile: translates numeric measures to where expressions" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.where, predicates[0].op);
    const where_expr = predicates[0].where.?;
    try std.testing.expectEqual(@as(usize, 2), where_expr.any.len);
    try std.testing.expectEqual(@as(u32, 10), where_expr.any[0].compare.right.number);
    try std.testing.expectEqual(@as(u32, 3), where_expr.any[1].compare.right.number);
    try std.testing.expect(compiled.needs_measures);
}

test "compile: builds message segments from call placeholders" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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

    const excluded = try runCompiled(gpa, &registry, &compiled, .ts, "console.log(1);\n", "vendor/x.ts");
    defer gpa.free(excluded);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);

    const included = try runCompiled(gpa, &registry, &compiled, .ts, "console.log(1);\n", "src/x.ts");
    defer gpa.free(included);
    try std.testing.expectEqual(@as(usize, 1), included.len);
}

test "compile: matches anonymous operator tokens" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
        \\rule no-logical-and {
        \\  lang ts
        \\  match binary_expression @match {
        \\    operator: "&&"
        \\  }
        \\  emit @match { message "no &&" }
        \\}
    );
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &registry, &compiled, .ts, "const x = a && b;\nconst y = a || b;\n", null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
}

test "compile: matches alternation node kinds" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
        \\rule no-boolean-literal {
        \\  lang ts
        \\  match [true, false] @match
        \\  emit @match { message "no boolean literal" }
        \\}
    );
    defer compiled.deinit();

    const diags = try runCompiled(gpa, &registry, &compiled, .ts, "const x = true;\nconst y = 1;\n", null);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 1), diags.len);
}

test "compile: skips project rules and other languages" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    var registry: language.Registry = .init();

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
        try std.testing.expectError(case.err, compileDsl(gpa, &registry, arena.allocator(), .ts, case.source));
    }
}

test "compile: folds string disjunctions into any-of" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.any_of, predicates[0].op);
    try std.testing.expectEqual(@as(usize, 4), predicates[0].args.len);
    try std.testing.expectEqualStrings("toBeDefined", predicates[0].args[1].string);
    try std.testing.expectEqualStrings("toBeNull", predicates[0].args[2].string);
    try std.testing.expectEqualStrings("toBeTruthy", predicates[0].args[3].string);
}

test "compile: negated string disjunction becomes not-any-of" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.not_any_of, predicates[0].op);
    try std.testing.expectEqual(@as(usize, 3), predicates[0].args.len);
}

test "compile: disjunction across different captures is unsupported" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    const got = compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .go,
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
    try std.testing.expectEqual(rule.PredicateOp.has, predicates[0].op);
    const nested = predicates[0].nested.?;
    try std.testing.expect(nested.root_capture_id != rule.invalid_capture_id);
    try std.testing.expectEqual(@as(usize, 1), nested.predicates.len);
    try std.testing.expectEqual(rule.PredicateOp.eq, nested.predicates[0].op);
    try std.testing.expectEqualStrings("panic", nested.predicates[0].args[1].string);
    try std.testing.expectEqual(@as(usize, 1), compiled.nested_queries.len);
    try std.testing.expect(!compiled.needs_measures);
}

test "compile: reuses a bound nested root capture" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.not_inside, predicates[0].op);
    const nested = predicates[0].nested.?;
    try std.testing.expectEqual(rule.captureIdForName(nested.query, "cls"), nested.root_capture_id);
}

test "compile: translates count with a comparison" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.count, predicates[0].op);
    try std.testing.expect(predicates[0].nested != null);
    try std.testing.expectEqual(expr.Compare.gt, predicates[0].count.?.op);
    try std.testing.expectEqual(@as(u32, 3), predicates[0].count.?.value);
}

test "compile: unknown subject capture in composition fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

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
    try std.testing.expectError(error.UnknownCapture, compile.compile(gpa, &registry, .ts, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("unknown capture", diag.detail);
}

test "compile: invalid node kind in a nested matcher fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

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
    try std.testing.expectError(error.QueryCompileFailed, compile.compile(gpa, &registry, .ts, file, &diag));
    try std.testing.expectEqualStrings("bad", diag.rule_id);
    try std.testing.expectEqualStrings("node kind or field is invalid for the grammar", diag.detail);
}

test "compile: reserved nested root capture fails" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

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
    try std.testing.expectError(error.ReservedCapture, compile.compile(gpa, &registry, .ts, file, &diag));
    try std.testing.expectEqualStrings("kata-nested-root is a reserved capture", diag.detail);
}

test "compile: measures in a nested where set needs_measures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.starts_with, predicates[0].op);
    try std.testing.expectEqual(rule.PredicateOp.not_ends_with, predicates[1].op);
    try std.testing.expectEqual(rule.PredicateOp.contains, predicates[2].op);
    try std.testing.expectEqual(rule.PredicateOp.not_contains, predicates[3].op);
    try std.testing.expectEqualStrings("use", predicates[0].args[1].string);
    try std.testing.expectEqualStrings("Deprecated", predicates[1].args[1].string);
    try std.testing.expectEqualStrings("Effect", predicates[2].args[1].string);
    try std.testing.expectEqualStrings("Legacy", predicates[3].args[1].string);
}

test "compile: string helpers require two text arguments" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { startsWith(text(@id)) }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, &registry, .ts, file, &diag));
    try std.testing.expectEqualStrings("startsWith, endsWith, and contains expect (value, text)", diag.detail);
}

test "compile: translates capture presence predicates" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    var compiled = try compileDsl(gpa, &registry, arena.allocator(), .ts,
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
    try std.testing.expectEqual(rule.PredicateOp.captured, predicates[0].op);
    try std.testing.expectEqual(rule.PredicateOp.not_captured, predicates[1].op);
}

test "compile: capture predicate requires one capture argument" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry: language.Registry = .init();

    const file = try parseDsl(arena.allocator(),
        \\rule bad {
        \\  lang ts
        \\  match identifier @id
        \\  where { capture("id") }
        \\  emit @id { message "bad" }
        \\}
    );
    var diag: rule.Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedPredicate, compile.compile(gpa, &registry, .ts, file, &diag));
    try std.testing.expectEqualStrings("capture expects one capture argument", diag.detail);
}

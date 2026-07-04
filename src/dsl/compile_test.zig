const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const compile = @import("compile.zig");
const dsl_parser = @import("parser.zig");

const diagnostic = @import("../lint/diagnostic.zig");
const engine = @import("../lint/Engine.zig");
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
    try engine.runRule(gpa, compiled, cursor, tree.rootNode(), source, lang, path, null, &out);
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

const std = @import("std");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const convert = @import("convert.zig");
const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");
const kind_map = @import("kind_map.zig");
const language = @import("language.zig");
const node = @import("node.zig");

const Engine = @import("Engine.zig").Engine;
const fs = @import("../fs.zig");
const loader = @import("../sources.zig").loader;
const Fixture = @import("../test_fixture.zig").Fixture;

fn parse(grammar: *const ts.Language, source: []const u8) *ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(grammar) catch unreachable;
    return parser.parseString(source, null).?;
}

fn checkFixture(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    engine: *Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
) !void {
    const grammar = language.grammar(lang);
    const tree = parse(grammar, source);
    defer tree.destroy();

    var kinds = try kind_map.build(lang, grammar, gpa);
    defer gpa.free(kinds.kind_remap);

    var cloned = try convert.build(lang, grammar, tree.rootNode(), source, gpa);
    defer cloned.deinit(gpa);

    const ts_root = node.Node.from(tree.rootNode(), &kinds);
    const kata_root = node.Node.fromKata(&cloned, cloned.root());

    const ts_diags = try engine.lintRoot(arena, ts_root, source, lang, path);
    const kata_diags = try engine.lintRoot(arena, kata_root, source, lang, path);
    try expectSameDiagnostics(arena, ts_diags, kata_diags);

    var ts_facts = try facts.extract(gpa, ts_root, source, path, lang);
    defer ts_facts.deinit();
    var kata_facts = try facts.extract(gpa, kata_root, source, path, lang);
    defer kata_facts.deinit();
    try expectSameFacts(ts_facts, kata_facts);
}

fn expectSameDiagnostics(
    arena: std.mem.Allocator,
    ts_diags: []const diagnostic.Diagnostic,
    kata_diags: []const diagnostic.Diagnostic,
) !void {
    try std.testing.expectEqual(ts_diags.len, kata_diags.len);

    const claimed = try arena.alloc(bool, kata_diags.len);
    @memset(claimed, false);

    for (ts_diags) |want| {
        var found = false;
        for (kata_diags, claimed) |got, *taken| {
            if (taken.*) continue;
            if (!diagEql(want, got)) continue;
            taken.* = true;
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

fn diagEql(a: diagnostic.Diagnostic, b: diagnostic.Diagnostic) bool {
    return std.mem.eql(u8, a.rule_id, b.rule_id) and
        std.mem.eql(u8, a.language, b.language) and
        std.mem.eql(u8, a.message, b.message) and
        a.severity == b.severity and
        rangeEql(a.range, b.range);
}

fn rangeEql(a: diagnostic.Range, b: diagnostic.Range) bool {
    return a.start.line == b.start.line and a.start.column == b.start.column and
        a.end.line == b.end.line and a.end.column == b.end.column;
}

fn expectSameFacts(a: facts.FileFacts, b: facts.FileFacts) !void {
    try std.testing.expectEqual(a.classes.len, b.classes.len);
    for (a.classes, b.classes) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.start, y.start);
        try std.testing.expectEqual(x.end, y.end);
        try std.testing.expect(rangeEql(x.range, y.range));
    }

    try std.testing.expectEqual(a.methods.len, b.methods.len);
    for (a.methods, b.methods) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqualStrings(x.container, y.container);
        try std.testing.expectEqual(x.start, y.start);
        try std.testing.expect(rangeEql(x.range, y.range));
    }

    try std.testing.expectEqual(a.typed_decls.len, b.typed_decls.len);
    for (a.typed_decls, b.typed_decls) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqualStrings(x.type_name, y.type_name);
        try std.testing.expectEqual(x.start, y.start);
    }

    try std.testing.expectEqual(a.calls.len, b.calls.len);
    for (a.calls, b.calls) |x, y| {
        try std.testing.expectEqualStrings(x.receiver, y.receiver);
        try std.testing.expectEqualStrings(x.method, y.method);
        try std.testing.expectEqualStrings(x.container, y.container);
        try std.testing.expectEqual(x.start, y.start);
    }

    try std.testing.expectEqual(a.imports.len, b.imports.len);
    for (a.imports, b.imports) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqualStrings(x.source, y.source);
        try std.testing.expectEqual(x.start, y.start);
    }
}

test "parity: kata backend matches tree-sitter over the fixture corpus" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_set = try loader.load(arena, std.testing.io, .{ .project_dir = "rules", .skip_embedded = true });
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &rule_set);
    defer engine.deinit();
    try engine.prewarm();

    const fixtures = try fs.rules.collectFixtureFiles(std.testing.io, arena, "rules");
    try std.testing.expect(fixtures.len > 0);

    for (fixtures) |fixture| {
        try checkFixture(gpa, arena, &engine, fixture.lang, fixture.source, fixture.path);
    }
}

test "parity: go multi-name parameter counting agrees on both backends" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rule =
        \\rule go-max-params {
        \\  lang go
        \\  match function_declaration @match
        \\  where { params(@match) > 1 }
        \\  emit @match { message "too many params {params(@match)}" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.go}, "go-max-params", rule);
    defer f.deinit();

    const source =
        \\package main
        \\
        \\func f(a, b, c int) int { return a }
        \\func g(a int) int { return a }
        \\
    ;
    try checkFixture(gpa, arena_state.allocator(), &f.engine, .go, source, "src/main.go");
}

test "parity: bool-op complexity refinement agrees on both backends" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const rule =
        \\rule noop {
        \\  lang ts
        \\  match debugger_statement @match
        \\  emit @match { message "noop" }
        \\}
    ;
    var f = try Fixture.init(gpa, &.{.ts}, "noop", rule);
    defer f.deinit();
    f.engine.metrics.set(.complexity, 1);

    const source =
        \\function f(a, b, c, d) {
        \\  return a && b || c ?? d;
        \\}
        \\
    ;
    try checkFixture(gpa, arena_state.allocator(), &f.engine, .ts, source, "src/a.ts");
}

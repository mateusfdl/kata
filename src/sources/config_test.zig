const std = @import("std");

const lint = @import("engine");
const config = @import("config.zig");
const lifecycle = @import("lifecycle.zig");
const loader = @import("loader.zig");

const language = lint.language;

fn expectParseOk(source: []const u8) !config.Config {
    var diag: config.Diagnostic = .{};
    return try config.parse(std.testing.allocator, source, &diag);
}

fn expectParseErr(source: []const u8, expected_err: anyerror, expected_line: u32) !void {
    var diag: config.Diagnostic = .{};
    const got = config.parse(std.testing.allocator, source, &diag);
    try std.testing.expectError(expected_err, got);
    try std.testing.expectEqual(expected_line, diag.line);
}

test "config: empty source yields no settings" {
    var cfg = try expectParseOk("");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.settings.len);
}

test "config: only comments yields no settings" {
    var cfg = try expectParseOk("# this is a comment\n# another\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.settings.len);
}

test "config: retired list keys are unknown" {
    try expectParseErr("enabled:\n  - ts/no-console\n", error.UnknownTopLevelKey, 1);
    try expectParseErr("disabled:\n  - ts/no-console\n", error.UnknownTopLevelKey, 1);
    try expectParseErr("warnings:\n  - ts/no-console\n", error.UnknownTopLevelKey, 1);
}

test "config: ratchet defaults to false" {
    var cfg = try expectParseOk("");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.ratchet);
}

test "config: parses ratchet true" {
    var cfg = try expectParseOk("ratchet: true\n");
    defer cfg.deinit();
    try std.testing.expectEqual(true, cfg.ratchet);
}

test "config: parses ratchet false" {
    var cfg = try expectParseOk("ratchet: false\n");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.ratchet);
}

test "config: ratchet rejects non-boolean values" {
    try expectParseErr("ratchet: yes\n", error.InvalidRatchetValue, 1);
}

test "config: CRLF line endings are tolerated" {
    var cfg = try expectParseOk("rules:\r\n  go:\r\n    no-panic:\r\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings.len);
}

test "config: tab in indent is rejected with line number" {
    try expectParseErr("rules:\n\tgo:\n", error.TabInIndent, 2);
}

test "config: unknown top-level key is rejected with line number" {
    try expectParseErr("disable:\n  - ts/no-console\n", error.UnknownTopLevelKey, 1);
}

test "config: malformed exclude item is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n      exclude:\n        -\n", error.MalformedListItem, 5);
}

test "config: bad indent is rejected" {
    try expectParseErr("ratchet: true\n   - ts/no-console\n", error.BadIndent, 2);
}

test "config: list item without preceding key is rejected" {
    try expectParseErr("  - ts/no-console\n", error.UnexpectedListItem, 1);
}

test "config: content after key without colon is rejected" {
    try expectParseErr("rules here\n", error.UnknownTopLevelKey, 1);
}

test "config: misspelled scalar key reports an unknown key" {
    try expectParseErr("rachet: true\n", error.UnknownTopLevelKey, 1);
}

test "config: inline content after a known key is rejected" {
    try expectParseErr("project-rules: no-console\n", error.ContentAfterKey, 1);
}

const RuleFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    set: loader.RuleSet,

    fn init() RuleFixture {
        return .{
            .arena_state = .init(std.testing.allocator),
            .set = undefined,
        };
    }

    fn arena(self: *RuleFixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn build(self: *RuleFixture) !void {
        self.set = .{ .allocator = self.arena() };
        try self.set.append(.ts, .{ .id = "no-console", .source = "((call_expression) @match)" });
        try self.set.append(.ts, .{ .id = "no-any", .source = "((type_annotation) @match)" });
        try self.set.append(.tsx, .{ .id = "no-any", .source = "((type_annotation) @match)" });
        try self.set.append(.tsx, .{ .id = "no-console", .source = "((call_expression) @match)" });
        try self.set.append(.go, .{ .id = "no-swallowed-errors", .source = "((short_var_declaration) @match)" });
    }

    fn deinit(self: *RuleFixture) void {
        self.set.deinit();
        self.arena_state.deinit();
    }

    fn countTs(self: *RuleFixture) usize {
        return self.set.get(.ts).len;
    }

    fn countTsx(self: *RuleFixture) usize {
        return self.set.get(.tsx).len;
    }

    fn countGo(self: *RuleFixture) usize {
        return self.set.get(.go).len;
    }
};

fn hasId(rules: []const lint.rule.RawRule, id: []const u8) bool {
    for (rules) |r| {
        if (std.mem.eql(u8, r.id, id)) return true;
    }
    return false;
}

fn dslRule(comptime id: []const u8, comptime lang: []const u8, comptime clauses: []const u8) []const u8 {
    return "rule " ++ id ++ " {\n" ++ clauses ++
        "  lang " ++ lang ++ "\n" ++
        "  match identifier @id\n" ++
        "  emit @id { message \"m\" }\n" ++
        "}\n";
}

fn buildTable(fx: *RuleFixture) !lifecycle.Table {
    var rule_diag: lint.rule.Diagnostic = .{};
    return lifecycle.build(fx.arena(), &fx.set, &rule_diag);
}

fn select(fx: *RuleFixture, resolved: config.Resolved) !void {
    var r = resolved;
    const table = try buildTable(fx);
    var diag: lint.rule.Diagnostic = .{};
    try config.applySelection(fx.arena(), &fx.set, &r, &table, &diag);
}

test "selection: no configs removes every rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    try select(&fx, try config.resolve(fx.arena(), null, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: config without rules key removes every rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("ratchet: true\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: scoped rule keeps exactly one rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("rules:\n  ts:\n    no-console:\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(hasId(fx.set.get(.ts), "no-console"));
}

test "selection: typescript scope keeps the rule in ts and tsx" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("rules:\n  typescript:\n    no-console:\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "selection: enabled false prunes a rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk(
        \\rules:
        \\  typescript:
        \\    no-any:
        \\  ts:
        \\    no-console:
        \\      enabled: false
        \\  tsx:
        \\    no-console:
        \\
    );
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 2), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(!hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.ts), "no-any"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "selection: rule entry matching nothing is ignored" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("rules:\n  ts:\n    no-console:\n    made-up:\n    no-such-rule:\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: former id activates the canonical rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    fx.set = .{ .allocator = fx.arena() };
    try fx.set.append(.ts, .{ .id = "new-name", .source = dslRule("new-name", "ts", "  former-ids old-name\n") });
    const table = try buildTable(&fx);

    var cfg = try expectParseOk("rules:\n  ts:\n    old-name:\n      severity: warn\n");
    defer cfg.deinit();
    var resolved = try config.resolve(fx.arena(), &cfg, null);
    var diag: lint.rule.Diagnostic = .{};
    try config.applySelection(fx.arena(), &fx.set, &resolved, &table, &diag);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expect(hasId(fx.set.get(.ts), "new-name"));
    try std.testing.expectEqual(@as(usize, 1), resolved.settings.len);
    try std.testing.expectEqualStrings("new-name", resolved.settings[0].id);
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, .warn), resolved.settings[0].severity);

    try std.testing.expectEqual(@as(usize, 1), fx.set.warnings.items.len);
    const w = fx.set.warnings.items[0];
    try std.testing.expectEqual(lint.Warning.Kind.renamed, w.kind);
    try std.testing.expectEqual(language.Name.ts, w.lang.?);
    try std.testing.expectEqualStrings("old-name", w.id);
    try std.testing.expectEqualStrings("new-name", w.canonical.?);
}

test "selection: former id under typescript scope warns once" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    fx.set = .{ .allocator = fx.arena() };
    try fx.set.append(.ts, .{ .id = "new-name", .source = dslRule("new-name", "ts, tsx", "  former-ids old-name\n") });
    try fx.set.append(.tsx, .{ .id = "new-name", .source = dslRule("new-name", "ts, tsx", "  former-ids old-name\n") });
    const table = try buildTable(&fx);

    var cfg = try expectParseOk("rules:\n  typescript:\n    old-name:\n");
    defer cfg.deinit();
    var resolved = try config.resolve(fx.arena(), &cfg, null);
    var diag: lint.rule.Diagnostic = .{};
    try config.applySelection(fx.arena(), &fx.set, &resolved, &table, &diag);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqualStrings("new-name", resolved.settings[0].id);
    try std.testing.expectEqualStrings("new-name", resolved.settings[1].id);
    try std.testing.expectEqual(@as(usize, 1), fx.set.warnings.items.len);
    try std.testing.expectEqual(lint.Warning.Kind.renamed, fx.set.warnings.items[0].kind);
}

test "selection: replaced retired id activates the replacement" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    fx.set = .{ .allocator = fx.arena() };
    try fx.set.append(.ts, .{ .id = "new-name", .source = dslRule("new-name", "ts", "") });
    var table = try buildTable(&fx);
    try table.retired.put(fx.arena(), "old-name", .{ .replaced = "new-name" });

    var cfg = try expectParseOk("rules:\n  ts:\n    old-name:\n");
    defer cfg.deinit();
    var resolved = try config.resolve(fx.arena(), &cfg, null);
    var diag: lint.rule.Diagnostic = .{};
    try config.applySelection(fx.arena(), &fx.set, &resolved, &table, &diag);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expect(hasId(fx.set.get(.ts), "new-name"));
    try std.testing.expectEqualStrings("new-name", resolved.settings[0].id);
    try std.testing.expectEqual(@as(usize, 1), fx.set.warnings.items.len);
    const w = fx.set.warnings.items[0];
    try std.testing.expectEqual(lint.Warning.Kind.renamed, w.kind);
    try std.testing.expectEqualStrings("old-name", w.id);
    try std.testing.expectEqualStrings("new-name", w.canonical.?);
}

test "selection: removed retired id fails with the recorded reason" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    fx.set = .{ .allocator = fx.arena() };
    try fx.set.append(.ts, .{ .id = "new-name", .source = dslRule("new-name", "ts", "") });
    var table = try buildTable(&fx);
    try table.retired.put(fx.arena(), "gone-name", .{ .removed = "superseded by the families seam" });

    var cfg = try expectParseOk("rules:\n  ts:\n    gone-name:\n");
    defer cfg.deinit();
    var resolved = try config.resolve(fx.arena(), &cfg, null);
    var diag: lint.rule.Diagnostic = .{};
    try std.testing.expectError(error.RetiredRuleRemoved, config.applySelection(fx.arena(), &fx.set, &resolved, &table, &diag));

    try std.testing.expectEqual(language.Name.ts, diag.lang.?);
    try std.testing.expectEqualStrings("gone-name", diag.rule_id);
    try std.testing.expectEqualStrings("removed: superseded by the families seam", diag.detail);
}

test "selection: live id never consults the retired registry" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    fx.set = .{ .allocator = fx.arena() };
    try fx.set.append(.ts, .{ .id = "no-console", .source = dslRule("no-console", "ts", "") });
    var table = try buildTable(&fx);
    try table.retired.put(fx.arena(), "no-console", .{ .removed = "should never be consulted" });

    var cfg = try expectParseOk("rules:\n  ts:\n    no-console:\n");
    defer cfg.deinit();
    var resolved = try config.resolve(fx.arena(), &cfg, null);
    var diag: lint.rule.Diagnostic = .{};
    try config.applySelection(fx.arena(), &fx.set, &resolved, &table, &diag);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.set.warnings.items.len);
}

test "config: parses an import-boundary project rule" {
    const src =
        \\project-rules:
        \\  domain-no-infra:
        \\    kind: import-boundary
        \\    from: src/domain/**
        \\    deny: src/infra/**
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.project_rules.len);
    const r = cfg.project_rules[0];
    try std.testing.expectEqualStrings("domain-no-infra", r.id);
    try std.testing.expectEqualStrings("src/domain/**", r.kind.import_boundary.from);
    try std.testing.expectEqualStrings("src/infra/**", r.kind.import_boundary.deny);
}

test "config: import-boundary without from is rejected" {
    const src =
        \\project-rules:
        \\  domain-no-infra:
        \\    kind: import-boundary
        \\    deny: src/infra/**
        \\
    ;
    try expectParseErr(src, error.IncompleteImportBoundary, 2);
}

test "config: import-boundary without deny is rejected" {
    const src =
        \\project-rules:
        \\  domain-no-infra:
        \\    kind: import-boundary
        \\    from: src/domain/**
        \\
    ;
    try expectParseErr(src, error.IncompleteImportBoundary, 2);
}

test "config: import-boundary with a restricted-callers key is rejected" {
    const src =
        \\project-rules:
        \\  domain-no-infra:
        \\    kind: import-boundary
        \\    from: src/domain/**
        \\    deny: src/infra/**
        \\    callee-suffix: Repository
        \\
    ;
    try expectParseErr(src, error.WrongKindProjectRuleKey, 2);
}

test "config: restricted-callers with an import-boundary key is rejected" {
    const src =
        \\project-rules:
        \\  repository-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Repository
        \\    from: src/domain/**
        \\
    ;
    try expectParseErr(src, error.WrongKindProjectRuleKey, 2);
}

test "errorMessage: returns descriptive text for known errors" {
    try std.testing.expectEqualStrings(
        "tabs are not allowed in indentation",
        config.errorMessage(error.TabInIndent),
    );
    try std.testing.expectEqualStrings(
        "unknown top-level key (expected 'rules', 'project-rules', or 'ratchet')",
        config.errorMessage(error.UnknownTopLevelKey),
    );
}

test "config: retired metrics key is an unknown top-level key" {
    try expectParseErr("metrics:\n  function-length: 80\n", error.UnknownTopLevelKey, 1);
}

test "config: parses a project rule" {
    const src =
        \\project-rules:
        \\  repository-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Repository
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.project_rules.len);
    const rule = cfg.project_rules[0];
    try std.testing.expectEqualStrings("repository-isolation", rule.id);
    try std.testing.expectEqualStrings("Repository", rule.kind.restricted_callers.callee_suffix);
    try std.testing.expectEqualStrings("Repository", rule.kind.restricted_callers.caller_suffix);
}

test "config: parses multiple project rules alongside other sections" {
    const src =
        \\rules:
        \\  ts:
        \\    no-console:
        \\project-rules:
        \\  repository-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Repository
        \\  gateway-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Gateway
        \\    caller-suffix: Service
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.project_rules.len);
    try std.testing.expectEqualStrings("gateway-isolation", cfg.project_rules[1].id);
    try std.testing.expectEqualStrings("Gateway", cfg.project_rules[1].kind.restricted_callers.callee_suffix);
    try std.testing.expectEqualStrings("Service", cfg.project_rules[1].kind.restricted_callers.caller_suffix);
}

test "config: unknown project rule kind is rejected" {
    const src = "project-rules:\n  r:\n    kind: taint-mode\n";
    try expectParseErr(src, error.UnknownProjectRuleKind, 3);
}

test "config: project rule without kind is rejected" {
    const src = "project-rules:\n  r:\n    callee-suffix: Repository\n    caller-suffix: Repository\n";
    try expectParseErr(src, error.MissingProjectRuleKind, 2);
}

test "config: project rule missing suffixes is rejected" {
    const src = "project-rules:\n  r:\n    kind: restricted-callers\n";
    try expectParseErr(src, error.IncompleteRestrictedCallers, 2);
}

test "config: unknown project rule key is rejected" {
    const src = "project-rules:\n  r:\n    kind: restricted-callers\n    color: red\n";
    try expectParseErr(src, error.UnknownProjectRuleKey, 4);
}

test "config: project rule property without a rule is rejected" {
    try expectParseErr("project-rules:\n    kind: restricted-callers\n", error.BadIndent, 2);
}

test "config: four-space indent outside project rules is rejected" {
    try expectParseErr("ratchet: true\n    - ts/no-console\n", error.BadIndent, 2);
}

test "config: project rule entry without colon is rejected" {
    try expectParseErr("project-rules:\n  repository-isolation\n", error.MalformedProjectRuleEntry, 2);
}

test "config: top-level keys record presence" {
    var cfg = try expectParseOk("project-rules:\nratchet: false\n");
    defer cfg.deinit();
    try std.testing.expectEqual(true, cfg.present.project_rules);
    try std.testing.expectEqual(true, cfg.present.ratchet);
}

test "config: empty source records no presence" {
    var cfg = try expectParseOk("");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.present.project_rules);
    try std.testing.expectEqual(false, cfg.present.ratchet);
}

test "resolve: no configs yields defaults" {
    const r = try config.resolve(std.testing.allocator, null, null);
    try std.testing.expectEqual(@as(usize, 0), r.settings.len);
    try std.testing.expectEqual(@as(usize, 0), r.project_rules.len);
    try std.testing.expectEqual(false, r.ratchet);
}

test "resolve: global only passes through every key" {
    const src =
        \\rules:
        \\  go:
        \\    no-panic:
        \\ratchet: true
        \\
    ;
    var g = try expectParseOk(src);
    defer g.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, null);
    try std.testing.expectEqual(@as(usize, 1), r.settings.len);
    try std.testing.expectEqualStrings("no-panic", r.settings[0].id);
    try std.testing.expectEqual(true, r.ratchet);
}

test "resolve: project empty rules key inherits global settings" {
    var g = try expectParseOk("rules:\n  ts:\n    no-console:\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.settings.len);
    try std.testing.expectEqualStrings("no-console", r.settings[0].id);
}

test "resolve: omitted project keys fall through to global" {
    const global_src =
        \\project-rules:
        \\  repository-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Repository
        \\
    ;
    var g = try expectParseOk(global_src);
    defer g.deinit();
    var p = try expectParseOk("ratchet: true\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.project_rules.len);
    try std.testing.expectEqualStrings("repository-isolation", r.project_rules[0].id);
    try std.testing.expectEqual(true, r.ratchet);
}

test "resolve: explicit project ratchet false overrides global true" {
    var g = try expectParseOk("ratchet: true\n");
    defer g.deinit();
    var p = try expectParseOk("ratchet: false\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(false, r.ratchet);
}

test "resolve: project rules replace global project rules" {
    const global_src =
        \\project-rules:
        \\  repo-only-through-service:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Service
        \\
    ;
    const project_src =
        \\project-rules:
        \\  no-domain-to-infra:
        \\    kind: import-boundary
        \\    from: src/domain
        \\    deny: src/infra
        \\
    ;
    var g = try expectParseOk(global_src);
    defer g.deinit();
    var p = try expectParseOk(project_src);
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.project_rules.len);
    try std.testing.expectEqualStrings("no-domain-to-infra", r.project_rules[0].id);
}

test "selection: project raws need a project scope entry" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();
    try fx.set.upsertProject(.{ .id = "isolation", .source = "1" }, .project);
    try fx.set.upsertProject(.{ .id = "boundaries", .source = "2" }, .project);

    var cfg = try expectParseOk("rules:\n  project:\n    isolation:\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.set.projectRaws().len);
    try std.testing.expectEqualStrings("isolation", fx.set.projectRaws()[0].id);
}

test "selection: project scope never enables language rules" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("rules:\n  project:\n    no-console:\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
}

test "selection: project scope enabled false prunes a project raw" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();
    try fx.set.upsertProject(.{ .id = "isolation", .source = "1" }, .project);
    try fx.set.upsertProject(.{ .id = "boundaries", .source = "2" }, .project);

    var cfg = try expectParseOk("rules:\n  project:\n    isolation:\n    boundaries:\n      enabled: false\n");
    defer cfg.deinit();
    try select(&fx, try config.resolve(fx.arena(), &cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.set.projectRaws().len);
    try std.testing.expectEqualStrings("isolation", fx.set.projectRaws()[0].id);
}

test "resolve: project setting replaces the matching global rule" {
    var g = try expectParseOk("rules:\n  go:\n    no-panic:\n      severity: warn\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n  go:\n    no-panic:\n      enabled: false\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.settings.len);
    try std.testing.expectEqual(false, r.settings[0].enabled);
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, null), r.settings[0].severity);
}

test "resolve: unlisted rules inherit from global settings" {
    var g = try expectParseOk("rules:\n  go:\n    no-panic:\n    max-nesting:\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n  go:\n    max-nesting:\n      enabled: false\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 2), r.settings.len);
    try std.testing.expectEqualStrings("no-panic", r.settings[0].id);
    try std.testing.expectEqual(true, r.settings[0].enabled);
    try std.testing.expectEqualStrings("max-nesting", r.settings[1].id);
    try std.testing.expectEqual(false, r.settings[1].enabled);
}

test "resolve: project adds a new rule to the global settings" {
    var g = try expectParseOk("rules:\n  go:\n    no-panic:\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n  ts:\n    no-console:\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 2), r.settings.len);
    try std.testing.expectEqualStrings("no-panic", r.settings[0].id);
    try std.testing.expectEqual(@as(?language.Name, .ts), r.settings[1].lang);
    try std.testing.expectEqualStrings("no-console", r.settings[1].id);
}

test "resolve: project without rules key inherits global settings" {
    var g = try expectParseOk("rules:\n  go:\n    no-panic:\n");
    defer g.deinit();
    var p = try expectParseOk("ratchet: true\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.settings.len);
    try std.testing.expectEqualStrings("no-panic", r.settings[0].id);
    try std.testing.expectEqual(true, r.ratchet);
}

test "resolve: narrow ts entry overrides only the ts half of a global typescript entry" {
    var g = try expectParseOk("rules:\n  typescript:\n    no-any:\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n  ts:\n    no-any:\n      enabled: false\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 2), r.settings.len);
    try std.testing.expectEqual(@as(?language.Name, .ts), r.settings[0].lang);
    try std.testing.expectEqual(false, r.settings[0].enabled);
    try std.testing.expectEqual(@as(?language.Name, .tsx), r.settings[1].lang);
    try std.testing.expectEqual(true, r.settings[1].enabled);
}

test "resolve: project setting overrides a global project scope setting" {
    var g = try expectParseOk("rules:\n  project:\n    isolation:\n");
    defer g.deinit();
    var p = try expectParseOk("rules:\n  project:\n    isolation:\n      enabled: false\n");
    defer p.deinit();

    const r = try config.resolve(g.arena.allocator(), &g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.settings.len);
    try std.testing.expectEqual(true, r.settings[0].project);
    try std.testing.expectEqual(false, r.settings[0].enabled);
}

test "rules: empty rules key yields no settings" {
    var cfg = try expectParseOk("rules:\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.settings.len);
}

test "rules: bare rule entry defaults to enabled" {
    var cfg = try expectParseOk("rules:\n  go:\n    no-panic:\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings.len);
    const s = cfg.settings[0];
    try std.testing.expectEqual(@as(?language.Name, .go), s.lang);
    try std.testing.expectEqualStrings("no-panic", s.id);
    try std.testing.expectEqual(false, s.project);
    try std.testing.expectEqual(true, s.enabled);
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, null), s.severity);
    try std.testing.expectEqual(@as(usize, 0), s.exclude.len);
}

test "rules: enabled false is parsed" {
    var cfg = try expectParseOk("rules:\n  go:\n    max-nesting:\n      enabled: false\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings.len);
    try std.testing.expectEqual(false, cfg.settings[0].enabled);
}

test "rules: enabled true is parsed" {
    var cfg = try expectParseOk("rules:\n  go:\n    max-nesting:\n      enabled: true\n");
    defer cfg.deinit();
    try std.testing.expectEqual(true, cfg.settings[0].enabled);
}

test "rules: severity warn is parsed" {
    var cfg = try expectParseOk("rules:\n  go:\n    no-panic:\n      severity: warn\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, .warn), cfg.settings[0].severity);
}

test "rules: severity error is parsed" {
    var cfg = try expectParseOk("rules:\n  go:\n    no-panic:\n      severity: error\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, .@"error"), cfg.settings[0].severity);
}

test "rules: typescript expands to ts and tsx" {
    const src =
        \\rules:
        \\  typescript:
        \\    simple-repositories:
        \\      exclude:
        \\        - 'test/**/*.ts'
        \\        - src/gen/**
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.settings.len);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.settings[0].lang);
    try std.testing.expectEqual(@as(?language.Name, .tsx), cfg.settings[1].lang);
    for (cfg.settings) |s| {
        try std.testing.expectEqualStrings("simple-repositories", s.id);
        try std.testing.expectEqual(@as(usize, 2), s.exclude.len);
        try std.testing.expectEqualStrings("test/**/*.ts", s.exclude[0]);
        try std.testing.expectEqualStrings("src/gen/**", s.exclude[1]);
    }
}

test "rules: double-quoted exclude item is unquoted" {
    var cfg = try expectParseOk("rules:\n  go:\n    no-panic:\n      exclude:\n        - \"cmd/**\"\n");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("cmd/**", cfg.settings[0].exclude[0]);
}

test "rules: property after exclude list ends the list" {
    const src =
        \\rules:
        \\  go:
        \\    no-panic:
        \\      exclude:
        \\        - cmd/**
        \\      severity: warn
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings[0].exclude.len);
    try std.testing.expectEqual(@as(?lint.diagnostic.Severity, .warn), cfg.settings[0].severity);
}

test "rules: project scope yields a project setting" {
    var cfg = try expectParseOk("rules:\n  project:\n    isolation:\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.settings.len);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.settings[0].lang);
    try std.testing.expectEqual(true, cfg.settings[0].project);
    try std.testing.expectEqualStrings("isolation", cfg.settings[0].id);
}

test "rules: multiple scopes with comments and blank lines" {
    const src =
        \\rules:
        \\  go:
        \\    no-panic:  # keep
        \\    max-nesting:
        \\      enabled: false
        \\
        \\  ts:
        \\    no-void:
        \\ratchet: true
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg.settings.len);
    try std.testing.expectEqualStrings("no-panic", cfg.settings[0].id);
    try std.testing.expectEqual(true, cfg.settings[0].enabled);
    try std.testing.expectEqualStrings("max-nesting", cfg.settings[1].id);
    try std.testing.expectEqual(false, cfg.settings[1].enabled);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.settings[2].lang);
    try std.testing.expectEqualStrings("no-void", cfg.settings[2].id);
    try std.testing.expectEqual(true, cfg.ratchet);
}

test "rules: unknown scope is rejected" {
    try expectParseErr("rules:\n  rust:\n", error.UnknownScope, 2);
}

test "rules: scope without colon is rejected" {
    try expectParseErr("rules:\n  go\n", error.UnknownScope, 2);
}

test "rules: unknown rule key is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n      foo: bar\n", error.UnknownRuleKey, 4);
}

test "rules: invalid enabled value is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n      enabled: yes\n", error.InvalidEnabledValue, 4);
}

test "rules: invalid severity value is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n      severity: info\n", error.InvalidSeverityValue, 4);
}

test "rules: duplicate rule is rejected at the second occurrence" {
    const src =
        \\rules:
        \\  go:
        \\    no-panic:
        \\    no-panic:
        \\      enabled: false
        \\
    ;
    try expectParseErr(src, error.DuplicateRule, 4);
}

test "rules: typescript and ts overlap is rejected" {
    const src =
        \\rules:
        \\  typescript:
        \\    no-any:
        \\  ts:
        \\    no-any:
        \\
    ;
    try expectParseErr(src, error.DuplicateRule, 5);
}

test "rules: invalid rule id is rejected" {
    try expectParseErr("rules:\n  go:\n    no.panic:\n", error.InvalidRuleId, 3);
}

test "rules: rule entry without colon is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic\n", error.MalformedRuleEntry, 3);
}

test "rules: property without a rule is rejected" {
    try expectParseErr("rules:\n  go:\n      enabled: false\n", error.BadIndent, 3);
}

test "rules: rule entry without a scope is rejected" {
    try expectParseErr("rules:\n    no-panic:\n", error.BadIndent, 2);
}

test "rules: exclude item without exclude key is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n        - cmd/**\n", error.BadIndent, 4);
}

test "rules: inline content after rules key is rejected" {
    try expectParseErr("rules: go\n", error.ContentAfterKey, 1);
}

test "rules: inline content after scope key is rejected" {
    try expectParseErr("rules:\n  go: no-panic\n", error.ContentAfterKey, 2);
}

test "rules: inline content after exclude key is rejected" {
    try expectParseErr("rules:\n  go:\n    no-panic:\n      exclude: cmd/**\n", error.ContentAfterKey, 4);
}

test "rules: odd indent is rejected" {
    try expectParseErr("rules:\n   go:\n", error.BadIndent, 2);
}

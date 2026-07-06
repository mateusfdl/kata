const std = @import("std");

const lint = @import("../lint.zig");
const config = @import("config.zig");
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

test "config: empty source yields empty disables" {
    var cfg = try expectParseOk("");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled.len);
}

test "config: only comments yields empty disables" {
    var cfg = try expectParseOk("# this is a comment\n# another\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled.len);
}

test "config: disabled key with no items yields empty disables" {
    var cfg = try expectParseOk("disabled:\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled.len);
}

test "config: parses a single scoped entry" {
    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.disabled[0].lang);
    try std.testing.expectEqualStrings("no-console", cfg.disabled[0].id);
}

test "config: parses a single bare entry" {
    var cfg = try expectParseOk("disabled:\n  - no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.disabled[0].lang);
    try std.testing.expectEqualStrings("no-console", cfg.disabled[0].id);
}

test "config: parses mixed scoped and bare entries" {
    const src =
        \\disabled:
        \\  - ts/no-console
        \\  - no-any
        \\  - tsx/no-comments
        \\  - go/no-swallowed-errors
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 4), cfg.disabled.len);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.disabled[0].lang);
    try std.testing.expectEqualStrings("no-console", cfg.disabled[0].id);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.disabled[1].lang);
    try std.testing.expectEqualStrings("no-any", cfg.disabled[1].id);
    try std.testing.expectEqual(@as(?language.Name, .tsx), cfg.disabled[2].lang);
    try std.testing.expectEqualStrings("no-comments", cfg.disabled[2].id);
    try std.testing.expectEqual(@as(?language.Name, .go), cfg.disabled[3].lang);
    try std.testing.expectEqualStrings("no-swallowed-errors", cfg.disabled[3].id);
}

test "config: trailing comment is stripped" {
    var cfg = try expectParseOk("disabled:  # top-level\n  - ts/no-console  # the rule\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
    try std.testing.expectEqualStrings("no-console", cfg.disabled[0].id);
}

test "config: warnings default to empty" {
    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.warnings.len);
}

test "config: parses warnings list with scoped and bare entries" {
    const src =
        \\warnings:
        \\  - ts/max-complexity
        \\  - max-nesting
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.warnings.len);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.warnings[0].lang);
    try std.testing.expectEqualStrings("max-complexity", cfg.warnings[0].id);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.warnings[1].lang);
    try std.testing.expectEqualStrings("max-nesting", cfg.warnings[1].id);
}

test "config: warnings list rejects invalid rule id" {
    try expectParseErr("warnings:\n  - ts/no.console\n", error.InvalidRuleId, 2);
}

test "config: enabled defaults to empty" {
    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.enabled.len);
}

test "config: parses enabled list with scoped and bare entries" {
    const src =
        \\enabled:
        \\  - go/no-panic
        \\  - no-comments
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.enabled.len);
    try std.testing.expectEqual(@as(?language.Name, .go), cfg.enabled[0].lang);
    try std.testing.expectEqualStrings("no-panic", cfg.enabled[0].id);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.enabled[1].lang);
    try std.testing.expectEqualStrings("no-comments", cfg.enabled[1].id);
}

test "config: enabled list rejects invalid rule id" {
    try expectParseErr("enabled:\n  - ts/no.console\n", error.InvalidRuleId, 2);
}

test "config: enabled list rejects unknown language" {
    try expectParseErr("enabled:\n  - rust/no-unsafe\n", error.UnknownLanguage, 2);
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
    var cfg = try expectParseOk("disabled:\r\n  - ts/no-console\r\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
}

test "config: tab in indent is rejected with line number" {
    try expectParseErr("disabled:\n\t- ts/no-console\n", error.TabInIndent, 2);
}

test "config: unknown top-level key is rejected with line number" {
    try expectParseErr("disable:\n  - ts/no-console\n", error.UnknownTopLevelKey, 1);
}

test "config: malformed list item is rejected" {
    try expectParseErr("disabled:\n  -\n", error.MalformedListItem, 2);
}

test "config: invalid rule id chars are rejected" {
    try expectParseErr("disabled:\n  - ts/no.console\n", error.InvalidRuleId, 2);
}

test "config: unknown language is rejected" {
    try expectParseErr("disabled:\n  - rust/no-unsafe\n", error.UnknownLanguage, 2);
}

test "config: bad indent is rejected" {
    try expectParseErr("disabled:\n    - ts/no-console\n", error.BadIndent, 2);
}

test "config: list item without preceding key is rejected" {
    try expectParseErr("  - ts/no-console\n", error.UnexpectedListItem, 1);
}

test "config: content after key without colon is rejected" {
    try expectParseErr("disabled here\n", error.UnknownTopLevelKey, 1);
}

test "config: misspelled scalar key reports an unknown key" {
    try expectParseErr("rachet: true\n", error.UnknownTopLevelKey, 1);
}

test "config: inline content after a known key is rejected" {
    try expectParseErr("disabled: ts/no-console\n", error.ContentAfterKey, 1);
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
        try self.set.append(.ts, .{ .id = "no-console", .language = .ts, .source = "((call_expression) @match)" });
        try self.set.append(.ts, .{ .id = "no-any", .language = .ts, .source = "((type_annotation) @match)" });
        try self.set.append(.tsx, .{ .id = "no-any", .language = .tsx, .source = "((type_annotation) @match)" });
        try self.set.append(.tsx, .{ .id = "no-console", .language = .tsx, .source = "((call_expression) @match)" });
        try self.set.append(.go, .{ .id = "no-swallowed-errors", .language = .go, .source = "((short_var_declaration) @match)" });
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

test "selection: no configs removes every rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    config.applySelection(&fx.set, config.resolve(null, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: config without enabled key removes every rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("disabled:\n  - ts/no-console\nratchet: true\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: scoped enable keeps exactly one rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("enabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(hasId(fx.set.get(.ts), "no-console"));
}

test "selection: bare enable keeps the rule across languages" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("enabled:\n  - no-console\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "selection: disabled prunes an enabled rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk(
        \\enabled:
        \\  - no-console
        \\  - no-any
        \\disabled:
        \\  - ts/no-console
        \\
    );
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 2), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(!hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.ts), "no-any"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "selection: enabled entry matching nothing is ignored" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("enabled:\n  - no-console\n  - made-up\n  - ts/no-such-rule\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
}

test "selection: warnings entry does not enable a rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("warnings:\n  - no-console\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
    try std.testing.expectEqual(@as(usize, 0), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
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
        "unknown top-level key (expected 'enabled', 'disabled', 'warnings', 'metrics', 'project-rules', or 'ratchet')",
        config.errorMessage(error.UnknownTopLevelKey),
    );
}

test "config: no metrics block leaves all metrics disabled" {
    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, null), cfg.metrics.get(.function_length));
}

test "config: parses metrics block" {
    var cfg = try expectParseOk("metrics:\n  function-length: 80\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 80), cfg.metrics.get(.function_length));
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled.len);
}

test "config: parses all metric names" {
    const src =
        \\metrics:
        \\  complexity: 15
        \\  nesting-depth: 4
        \\  function-length: 80
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 15), cfg.metrics.get(.complexity));
    try std.testing.expectEqual(@as(?u32, 4), cfg.metrics.get(.nesting_depth));
    try std.testing.expectEqual(@as(?u32, 80), cfg.metrics.get(.function_length));
}

test "config: metrics and disabled coexist" {
    const src =
        \\disabled:
        \\  - ts/no-console
        \\metrics:
        \\  function-length: 40
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
    try std.testing.expectEqual(@as(?u32, 40), cfg.metrics.get(.function_length));
}

test "config: metric entry tolerates trailing comment" {
    var cfg = try expectParseOk("metrics:\n  function-length: 80  # keep them short\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 80), cfg.metrics.get(.function_length));
}

test "config: unknown metric is rejected" {
    try expectParseErr("metrics:\n  line-count: 80\n", error.UnknownMetric, 2);
}

test "config: non-numeric threshold is rejected" {
    try expectParseErr("metrics:\n  function-length: many\n", error.InvalidThreshold, 2);
}

test "config: zero threshold is rejected" {
    try expectParseErr("metrics:\n  function-length: 0\n", error.InvalidThreshold, 2);
}

test "config: metric entry without colon is rejected" {
    try expectParseErr("metrics:\n  function-length 80\n", error.MalformedMetricEntry, 2);
}

test "config: metric entry without preceding key is rejected" {
    try expectParseErr("  function-length: 80\n", error.UnexpectedListItem, 1);
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
        \\disabled:
        \\  - ts/no-console
        \\project-rules:
        \\  repository-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Repository
        \\    caller-suffix: Repository
        \\  gateway-isolation:
        \\    kind: restricted-callers
        \\    callee-suffix: Gateway
        \\    caller-suffix: Service
        \\metrics:
        \\  complexity: 15
        \\
    ;
    var cfg = try expectParseOk(src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled.len);
    try std.testing.expectEqual(@as(?u32, 15), cfg.metrics.get(.complexity));
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
    try expectParseErr("disabled:\n    - ts/no-console\n", error.BadIndent, 2);
}

test "config: project rule entry without colon is rejected" {
    try expectParseErr("project-rules:\n  repository-isolation\n", error.MalformedProjectRuleEntry, 2);
}

test "config: top-level keys record presence" {
    var cfg = try expectParseOk("enabled:\ndisabled:\nwarnings:\nmetrics:\nproject-rules:\nratchet: false\n");
    defer cfg.deinit();
    try std.testing.expectEqual(true, cfg.present.enabled);
    try std.testing.expectEqual(true, cfg.present.disabled);
    try std.testing.expectEqual(true, cfg.present.warnings);
    try std.testing.expectEqual(true, cfg.present.metrics);
    try std.testing.expectEqual(true, cfg.present.project_rules);
    try std.testing.expectEqual(true, cfg.present.ratchet);
}

test "config: empty source records no presence" {
    var cfg = try expectParseOk("");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.present.enabled);
    try std.testing.expectEqual(false, cfg.present.disabled);
    try std.testing.expectEqual(false, cfg.present.warnings);
    try std.testing.expectEqual(false, cfg.present.metrics);
    try std.testing.expectEqual(false, cfg.present.project_rules);
    try std.testing.expectEqual(false, cfg.present.ratchet);
}

test "resolve: no configs yields defaults" {
    const r = config.resolve(null, null);
    try std.testing.expectEqual(@as(usize, 0), r.enabled.len);
    try std.testing.expectEqual(@as(usize, 0), r.disabled.len);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
    try std.testing.expectEqual(@as(usize, 0), r.project_rules.len);
    try std.testing.expectEqual(false, r.ratchet);
    try std.testing.expectEqual(@as(?u32, null), r.metrics.get(.complexity));
    try std.testing.expectEqual(@as(?u32, null), r.metrics.get(.nesting_depth));
    try std.testing.expectEqual(@as(?u32, null), r.metrics.get(.function_length));
}

test "resolve: global only passes through every key" {
    const src =
        \\enabled:
        \\  - go/no-panic
        \\disabled:
        \\  - ts/no-console
        \\warnings:
        \\  - max-complexity
        \\metrics:
        \\  complexity: 10
        \\ratchet: true
        \\
    ;
    var g = try expectParseOk(src);
    defer g.deinit();

    const r = config.resolve(&g, null);
    try std.testing.expectEqual(@as(usize, 1), r.enabled.len);
    try std.testing.expectEqualStrings("no-panic", r.enabled[0].id);
    try std.testing.expectEqual(@as(usize, 1), r.disabled.len);
    try std.testing.expectEqualStrings("no-console", r.disabled[0].id);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);
    try std.testing.expectEqualStrings("max-complexity", r.warnings[0].id);
    try std.testing.expectEqual(@as(?u32, 10), r.metrics.get(.complexity));
    try std.testing.expectEqual(true, r.ratchet);
}

test "resolve: project enabled list replaces global wholesale" {
    var g = try expectParseOk("enabled:\n  - ts/no-console\n  - no-any\n");
    defer g.deinit();
    var p = try expectParseOk("enabled:\n  - go/no-panic\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.enabled.len);
    try std.testing.expectEqual(@as(?language.Name, .go), r.enabled[0].lang);
    try std.testing.expectEqualStrings("no-panic", r.enabled[0].id);
}

test "resolve: project empty enabled list disables everything" {
    var g = try expectParseOk("enabled:\n  - ts/no-console\n");
    defer g.deinit();
    var p = try expectParseOk("enabled:\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 0), r.enabled.len);
}

test "resolve: omitted project enabled falls through to global" {
    var g = try expectParseOk("enabled:\n  - ts/no-console\n");
    defer g.deinit();
    var p = try expectParseOk("ratchet: true\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.enabled.len);
    try std.testing.expectEqualStrings("no-console", r.enabled[0].id);
}

test "resolve: project disabled list replaces global wholesale" {
    var g = try expectParseOk("disabled:\n  - ts/no-console\n  - no-any\n");
    defer g.deinit();
    var p = try expectParseOk("disabled:\n  - go/no-panic\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.disabled.len);
    try std.testing.expectEqual(@as(?language.Name, .go), r.disabled[0].lang);
    try std.testing.expectEqualStrings("no-panic", r.disabled[0].id);
}

test "resolve: project empty disabled list clears global disables" {
    var g = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer g.deinit();
    var p = try expectParseOk("disabled:\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 0), r.disabled.len);
}

test "resolve: omitted project keys fall through to global" {
    var g = try expectParseOk("disabled:\n  - ts/no-console\nmetrics:\n  complexity: 10\n");
    defer g.deinit();
    var p = try expectParseOk("ratchet: true\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.disabled.len);
    try std.testing.expectEqualStrings("no-console", r.disabled[0].id);
    try std.testing.expectEqual(@as(?u32, 10), r.metrics.get(.complexity));
    try std.testing.expectEqual(true, r.ratchet);
}

test "resolve: project metrics replace the global set" {
    var g = try expectParseOk("metrics:\n  complexity: 10\n  function-length: 50\n");
    defer g.deinit();
    var p = try expectParseOk("metrics:\n  nesting-depth: 3\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(?u32, null), r.metrics.get(.complexity));
    try std.testing.expectEqual(@as(?u32, null), r.metrics.get(.function_length));
    try std.testing.expectEqual(@as(?u32, 3), r.metrics.get(.nesting_depth));
}

test "resolve: explicit project ratchet false overrides global true" {
    var g = try expectParseOk("ratchet: true\n");
    defer g.deinit();
    var p = try expectParseOk("ratchet: false\n");
    defer p.deinit();

    const r = config.resolve(&g, &p);
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

    const r = config.resolve(&g, &p);
    try std.testing.expectEqual(@as(usize, 1), r.project_rules.len);
    try std.testing.expectEqualStrings("no-domain-to-infra", r.project_rules[0].id);
}

test "config: enabled accepts project scoped ids" {
    var cfg = try expectParseOk("enabled:\n  - project/repository-isolation\n  - ts/no-console\n");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.enabled.len);
    try std.testing.expectEqual(@as(?language.Name, null), cfg.enabled[0].lang);
    try std.testing.expectEqual(true, cfg.enabled[0].project);
    try std.testing.expectEqualStrings("repository-isolation", cfg.enabled[0].id);
    try std.testing.expectEqual(@as(?language.Name, .ts), cfg.enabled[1].lang);
    try std.testing.expectEqual(false, cfg.enabled[1].project);
}

test "selection: project raws need a project scoped enable" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();
    try fx.set.upsertProject(.{ .id = "isolation", .source = "1", .format = .kata }, .project);
    try fx.set.upsertProject(.{ .id = "boundaries", .source = "2", .format = .kata }, .project);

    var cfg = try expectParseOk("enabled:\n  - project/isolation\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.set.projectRaws().len);
    try std.testing.expectEqualStrings("isolation", fx.set.projectRaws()[0].id);
}

test "selection: project scoped ids never enable language rules" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("enabled:\n  - project/no-console\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 0), fx.countTs());
}

test "selection: bare ids enable project raws and disabled wins" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();
    try fx.set.upsertProject(.{ .id = "isolation", .source = "1", .format = .kata }, .project);
    try fx.set.upsertProject(.{ .id = "boundaries", .source = "2", .format = .kata }, .project);

    var cfg = try expectParseOk("enabled:\n  - isolation\n  - boundaries\ndisabled:\n  - project/boundaries\n");
    defer cfg.deinit();
    config.applySelection(&fx.set, config.resolve(&cfg, null));

    try std.testing.expectEqual(@as(usize, 1), fx.set.projectRaws().len);
    try std.testing.expectEqualStrings("isolation", fx.set.projectRaws()[0].id);
}

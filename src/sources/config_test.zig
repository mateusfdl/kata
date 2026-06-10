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

test "filter: scoped disable removes exactly one rule" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    config.filterDisabled(&fx.set, cfg);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 2), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 1), fx.countGo());
    try std.testing.expect(!hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "filter: bare disable removes across all languages" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("disabled:\n  - no-console\n");
    defer cfg.deinit();
    config.filterDisabled(&fx.set, cfg);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 1), fx.countGo());
    try std.testing.expect(!hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(!hasId(fx.set.get(.tsx), "no-console"));
}

test "filter: nonexistent id is a no-op" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk("disabled:\n  - ts/no-such-rule\n  - made-up\n");
    defer cfg.deinit();
    config.filterDisabled(&fx.set, cfg);

    try std.testing.expectEqual(@as(usize, 2), fx.countTs());
    try std.testing.expectEqual(@as(usize, 2), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 1), fx.countGo());
}

test "filter: combines scoped and bare across multiple langs" {
    var fx = RuleFixture.init();
    defer fx.deinit();
    try fx.build();

    var cfg = try expectParseOk(
        \\disabled:
        \\  - no-any
        \\  - go/no-swallowed-errors
        \\
    );
    defer cfg.deinit();
    config.filterDisabled(&fx.set, cfg);

    try std.testing.expectEqual(@as(usize, 1), fx.countTs());
    try std.testing.expectEqual(@as(usize, 1), fx.countTsx());
    try std.testing.expectEqual(@as(usize, 0), fx.countGo());
    try std.testing.expect(hasId(fx.set.get(.ts), "no-console"));
    try std.testing.expect(hasId(fx.set.get(.tsx), "no-console"));
}

test "errorMessage: returns descriptive text for known errors" {
    try std.testing.expectEqualStrings(
        "tabs are not allowed in indentation",
        config.errorMessage(error.TabInIndent),
    );
    try std.testing.expectEqualStrings(
        "unknown top-level key (expected 'disabled' or 'metrics')",
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

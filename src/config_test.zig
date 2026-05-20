const std = @import("std");

const config = @import("config.zig");
const language = @import("language.zig");
const loader = @import("loader.zig");

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
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_scoped.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_bare.len);
}

test "config: only comments yields empty disables" {
    var cfg = try expectParseOk("# this is a comment\n# another\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_scoped.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_bare.len);
}

test "config: disabled key with no items yields empty disables" {
    var cfg = try expectParseOk("disabled:\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_scoped.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_bare.len);
}

test "config: parses a single scoped entry" {
    var cfg = try expectParseOk("disabled:\n  - ts/no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled_scoped.len);
    try std.testing.expectEqual(language.Name.ts, cfg.disabled_scoped[0].lang);
    try std.testing.expectEqualStrings("no-console", cfg.disabled_scoped[0].id);
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_bare.len);
}

test "config: parses a single bare entry" {
    var cfg = try expectParseOk("disabled:\n  - no-console\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.disabled_scoped.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled_bare.len);
    try std.testing.expectEqualStrings("no-console", cfg.disabled_bare[0]);
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
    try std.testing.expectEqual(@as(usize, 3), cfg.disabled_scoped.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled_bare.len);
    try std.testing.expectEqualStrings("no-any", cfg.disabled_bare[0]);
    try std.testing.expectEqual(language.Name.ts, cfg.disabled_scoped[0].lang);
    try std.testing.expectEqualStrings("no-console", cfg.disabled_scoped[0].id);
    try std.testing.expectEqual(language.Name.tsx, cfg.disabled_scoped[1].lang);
    try std.testing.expectEqualStrings("no-comments", cfg.disabled_scoped[1].id);
    try std.testing.expectEqual(language.Name.go, cfg.disabled_scoped[2].lang);
    try std.testing.expectEqualStrings("no-swallowed-errors", cfg.disabled_scoped[2].id);
}

test "config: trailing comment is stripped" {
    var cfg = try expectParseOk("disabled:  # top-level\n  - ts/no-console  # the rule\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled_scoped.len);
    try std.testing.expectEqualStrings("no-console", cfg.disabled_scoped[0].id);
}

test "config: CRLF line endings are tolerated" {
    var cfg = try expectParseOk("disabled:\r\n  - ts/no-console\r\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.disabled_scoped.len);
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

fn hasId(rules: []const @import("rule.zig").RawRule, id: []const u8) bool {
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
        "unknown top-level key (expected 'disabled')",
        config.errorMessage(error.UnknownTopLevelKey),
    );
}

const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");
const loader = @import("loader.zig");
const matcher = @import("matcher.zig");
const rule = @import("rule.zig");

const initial_diagnostic_capacity: usize = 16;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    rules: *loader.RuleSet,
    compiled: std.EnumArray(language.Name, ?[]rule.CompiledRule) = .initFill(null),
    parsers: std.EnumArray(language.Name, ?*ts.Parser) = .initFill(null),
    cursor: *ts.QueryCursor,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *language.Registry,
        rules: *loader.RuleSet,
    ) Engine {
        return .{
            .allocator = allocator,
            .registry = registry,
            .rules = rules,
            .cursor = ts.QueryCursor.create(),
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            if (entry.value.*) |compiled| rule.destroyCompiled(self.allocator, compiled);
        }
        var pit = self.parsers.iterator();
        while (pit.next()) |entry| {
            if (entry.value.*) |parser| parser.destroy();
        }
        self.cursor.destroy();
    }

    pub fn prewarm(self: *Engine) !void {
        for (std.enums.values(language.Name)) |lang| {
            _ = try self.ensureCompiled(lang);
            _ = try self.ensureParser(lang);
        }
    }

    fn ensureParser(self: *Engine, lang: language.Name) !*ts.Parser {
        if (self.parsers.get(lang)) |cached| return cached;
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        parser.setLanguage(self.registry.get(lang)) catch return error.SetLanguageFailed;
        self.parsers.set(lang, parser);
        return parser;
    }

    fn ensureCompiled(self: *Engine, lang: language.Name) ![]rule.CompiledRule {
        if (self.compiled.get(lang)) |cached| return cached;
        const raws = self.rules.get(lang);
        const compiled = try rule.compile(self.allocator, self.registry, raws);
        self.compiled.set(lang, compiled);
        return compiled;
    }

    pub fn lint(
        self: *Engine,
        allocator: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
    ) ![]diagnostic.Diagnostic {
        const rules = try self.ensureCompiled(lang);
        const parser = try self.ensureParser(lang);
        const tree = parser.parseString(source, null) orelse return error.ParseFailed;
        defer tree.destroy();

        var out: std.ArrayList(diagnostic.Diagnostic) = try .initCapacity(allocator, initial_diagnostic_capacity);
        errdefer out.deinit(allocator);

        for (rules) |*r| {
            try runRule(allocator, r, self.cursor, tree.rootNode(), source, lang, &out);
        }

        return out.toOwnedSlice(allocator);
    }
};

fn runRule(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    cursor: *ts.QueryCursor,
    root: ts.Node,
    source: []const u8,
    lang: language.Name,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    if (r.match_capture_id == rule.invalid_capture_id) return;

    cursor.exec(r.query, root);
    const lang_str = lang.toString();

    while (cursor.nextMatch()) |match| {
        const meta = r.patterns[match.pattern_index];
        if (!matcher.evaluate(meta.predicates, match, source)) continue;

        const message = meta.message orelse meta.rule_id;
        try emitMatchDiagnostics(allocator, r, meta.rule_id, match, lang_str, message, out);
    }
}

fn emitMatchDiagnostics(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    rule_id: []const u8,
    match: ts.Query.Match,
    lang_str: []const u8,
    message: []const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    for (match.captures) |cap| {
        if (cap.index != r.match_capture_id) continue;
        const sp = cap.node.startPoint();
        const ep = cap.node.endPoint();
        try out.append(allocator, .{
            .rule_id = rule_id,
            .language = lang_str,
            .message = message,
            .range = .{
                .start = .{ .line = sp.row, .column = sp.column },
                .end = .{ .line = ep.row, .column = ep.column },
            },
        });
    }
}

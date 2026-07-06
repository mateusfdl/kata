const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const dsl_compile = @import("../dsl/compile.zig");
const facts = @import("facts.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");
const matcher = @import("matcher.zig");
const metric = @import("metric.zig");
const rule = @import("rule.zig");

const RuleSet = @import("RuleSet.zig").RuleSet;

const initial_diagnostic_capacity: usize = 16;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    rules: *RuleSet,
    compiled: std.EnumArray(language.Name, ?rule.CompiledRule) = .initFill(null),
    compiled_dsl: std.EnumArray(language.Name, ?rule.CompiledRule) = .initFill(null),
    parsers: std.EnumArray(language.Name, ?*ts.Parser) = .initFill(null),
    metrics: metric.Set = metric.empty,
    metric_queries: std.EnumArray(language.Name, ?metric.Compiled) = .initFill(null),
    facts_queries: std.EnumArray(language.Name, ?facts.Compiled) = .initFill(null),
    cursor: *ts.QueryCursor,
    metric_cursor: *ts.QueryCursor,
    warnings: []const rule.ScopedId = &.{},
    compile_diag: rule.Diagnostic = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *language.Registry,
        rules: *RuleSet,
    ) Engine {
        return .{
            .allocator = allocator,
            .registry = registry,
            .rules = rules,
            .cursor = ts.QueryCursor.create(),
            .metric_cursor = ts.QueryCursor.create(),
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            if (entry.value.*) |*compiled| compiled.deinit();
        }
        var dit = self.compiled_dsl.iterator();
        while (dit.next()) |entry| {
            if (entry.value.*) |*compiled| compiled.deinit();
        }
        var pit = self.parsers.iterator();
        while (pit.next()) |entry| {
            if (entry.value.*) |parser| parser.destroy();
        }
        var mit = self.metric_queries.iterator();
        while (mit.next()) |entry| {
            if (entry.value.*) |*compiled| compiled.deinit(self.allocator);
        }
        var fit = self.facts_queries.iterator();
        while (fit.next()) |entry| {
            if (entry.value.*) |*compiled| compiled.deinit(self.allocator);
        }
        self.cursor.destroy();
        self.metric_cursor.destroy();
    }

    pub fn prewarm(self: *Engine) !void {
        for (std.enums.values(language.Name)) |lang| {
            const compiled = try self.ensureCompiled(lang);
            const compiled_dsl = try self.ensureCompiledDsl(lang);
            _ = try self.ensureParser(lang);
            if (metric.anyEnabled(self.metrics) or needsMeasures(compiled, compiled_dsl)) _ = try self.ensureMetricQuery(lang);
        }
    }

    /// Prewarm and, on failure, write the compile diagnostic under `label`.
    /// Returns true when rules are ready, false when compilation failed.
    pub fn prewarmOrReport(self: *Engine, label: []const u8, stderr: *std.Io.Writer) !bool {
        self.prewarm() catch {
            try self.compile_diag.write(label, stderr);
            return false;
        };
        return true;
    }

    fn ensureParser(self: *Engine, lang: language.Name) !*ts.Parser {
        if (self.parsers.get(lang)) |cached| return cached;
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        parser.setLanguage(self.registry.get(lang)) catch return error.SetLanguageFailed;
        self.parsers.set(lang, parser);
        return parser;
    }

    fn ensureCompiled(self: *Engine, lang: language.Name) !*rule.CompiledRule {
        const slot = self.compiled.getPtr(lang);
        if (slot.*) |*cached| return cached;
        slot.* = try rule.compile(self.allocator, self.registry, lang, self.rules.get(lang), &self.compile_diag);
        return &slot.*.?;
    }

    fn ensureCompiledDsl(self: *Engine, lang: language.Name) !?*rule.CompiledRule {
        const slot = self.compiled_dsl.getPtr(lang);
        if (slot.*) |*cached| return cached;
        slot.* = (try dsl_compile.compileRaws(self.allocator, self.registry, lang, self.rules.get(lang), &self.compile_diag)) orelse return null;
        return &slot.*.?;
    }

    fn ensureMetricQuery(self: *Engine, lang: language.Name) !*metric.Compiled {
        const slot = self.metric_queries.getPtr(lang);
        if (slot.*) |*cached| return cached;
        slot.* = try metric.compile(self.allocator, self.registry.get(lang), lang);
        return &slot.*.?;
    }

    fn ensureFactsQuery(self: *Engine, lang: language.Name) !*facts.Compiled {
        const slot = self.facts_queries.getPtr(lang);
        if (slot.*) |*cached| return cached;
        slot.* = try facts.compile(self.allocator, self.registry.get(lang), lang);
        return &slot.*.?;
    }

    pub fn extractFacts(
        self: *Engine,
        gpa: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: []const u8,
    ) !facts.FileFacts {
        const compiled = try self.ensureFactsQuery(lang);
        const parser = try self.ensureParser(lang);
        const tree = parser.parseString(source, null) orelse return error.ParseFailed;
        defer tree.destroy();
        return facts.extract(gpa, compiled, self.cursor, tree.rootNode(), source, path, lang);
    }

    pub fn lint(
        self: *Engine,
        allocator: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: ?[]const u8,
    ) ![]diagnostic.Diagnostic {
        const compiled = try self.ensureCompiled(lang);
        const compiled_dsl = try self.ensureCompiledDsl(lang);
        const parser = try self.ensureParser(lang);
        const tree = parser.parseString(source, null) orelse return error.ParseFailed;
        defer tree.destroy();

        var out: std.ArrayList(diagnostic.Diagnostic) = try .initCapacity(allocator, initial_diagnostic_capacity);
        errdefer out.deinit(allocator);

        const metric_ctx: ?matcher.MetricContext = if (needsMeasures(compiled, compiled_dsl)) .{
            .allocator = allocator,
            .compiled = try self.ensureMetricQuery(lang),
            .cursor = self.metric_cursor,
            .lang = lang,
        } else null;

        try runRule(allocator, compiled, self.cursor, tree.rootNode(), source, lang, path, metric_ctx, &out);
        if (compiled_dsl) |dsl| try runRule(allocator, dsl, self.cursor, tree.rootNode(), source, lang, path, metric_ctx, &out);

        if (metric.anyEnabled(self.metrics)) {
            const metric_query = try self.ensureMetricQuery(lang);
            try metric.run(allocator, self.metrics, metric_query, self.cursor, tree.rootNode(), lang, &out);
        }

        demoteWarnings(self.warnings, lang, out.items);

        return out.toOwnedSlice(allocator);
    }
};

fn needsMeasures(compiled: *const rule.CompiledRule, compiled_dsl: ?*rule.CompiledRule) bool {
    if (compiled.needs_measures) return true;
    if (compiled_dsl) |dsl| return dsl.needs_measures;
    return false;
}

fn demoteWarnings(
    warnings: []const rule.ScopedId,
    lang: language.Name,
    diagnostics: []diagnostic.Diagnostic,
) void {
    for (diagnostics) |*d| {
        if (matchesWarning(warnings, lang, d.rule_id)) d.severity = .warn;
    }
}

fn matchesWarning(warnings: []const rule.ScopedId, lang: language.Name, rule_id: []const u8) bool {
    for (warnings) |w| {
        if (w.matches(lang, rule_id)) return true;
    }
    return false;
}

pub fn runRule(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    cursor: *ts.QueryCursor,
    root: ts.Node,
    source: []const u8,
    lang: language.Name,
    path: ?[]const u8,
    metric_ctx: ?matcher.MetricContext,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    if (r.match_capture_id == rule.invalid_capture_id) return;

    cursor.exec(r.query, root);
    const lang_str = lang.toString();

    while (cursor.nextMatch()) |match| {
        const meta = r.patterns[match.pattern_index];
        if (pathExcluded(meta.exclude_paths, path)) continue;
        if (!try matcher.evaluate(meta.predicates, match, source, metric_ctx)) continue;

        const message = if (meta.message) |m| switch (m) {
            .plain => |text| text,
            .segments => |segments| try matcher.renderMessage(allocator, segments, match, source, metric_ctx),
        } else meta.rule_id;
        try emitMatchDiagnostics(allocator, r, meta, match, lang_str, message, out);
    }
}

fn pathExcluded(globs: []const []const u8, path: ?[]const u8) bool {
    const p = path orelse return false;
    if (p.len == 0) return false;
    for (globs) |g| {
        if (glob.match(g, p)) return true;
    }
    return false;
}

fn emitMatchDiagnostics(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    meta: rule.PatternMeta,
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
            .rule_id = meta.rule_id,
            .language = lang_str,
            .message = message,
            .range = .{
                .start = .{ .line = sp.row, .column = sp.column },
                .end = .{ .line = ep.row, .column = ep.column },
            },
            .severity = meta.severity,
        });
    }
}

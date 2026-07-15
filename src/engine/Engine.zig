const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fact_rule = @import("fact_rule.zig");
const facts = @import("facts.zig");
const family_mod = @import("family/family.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");
const matcher = @import("matcher.zig");
const metric = @import("metric.zig");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const query = @import("query.zig");
const rule = @import("rule.zig");
const rule_compiler = @import("rule_compiler.zig");
const Node = @import("node.zig").Node;

const RuleSet = @import("RuleSet.zig").RuleSet;

const initial_diagnostic_capacity: usize = 16;

/// caches the outcome of rule compilation per language. `none` (no kata-format
/// rules exist) must be remembered too, leaving the slot empty would re-scan
/// the raw rules on every lint call
const RuleSlot = union(enum) {
    not_compiled,
    none,
    compiled: rule.CompiledRule,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    rules: *RuleSet,
    compiler: rule_compiler.RuleCompiler,
    compiled: std.EnumArray(language.Name, RuleSlot) = .initFill(.not_compiled),
    frontend: parse.Frontend,
    metric_queries: std.EnumArray(family_mod.Family, ?metric.Compiled) = .initFill(null),
    compiled_fact: ?[]const fact_rule.CompiledFactRule = null,
    fact_arena: ?*std.heap.ArenaAllocator = null,
    settings: []const rule.RuleSetting = &.{},
    compile_diag: rule.Diagnostic = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        rules: *RuleSet,
        compiler: rule_compiler.RuleCompiler,
    ) Engine {
        return .{
            .allocator = allocator,
            .rules = rules,
            .compiler = compiler,
            .frontend = parse.Frontend.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        var dit = self.compiled.iterator();
        while (dit.next()) |entry| {
            switch (entry.value.*) {
                .compiled => |*compiled| compiled.deinit(),
                .not_compiled, .none => {},
            }
        }

        self.frontend.deinit();

        var mit = self.metric_queries.iterator();
        while (mit.next()) |entry| {
            if (entry.value.*) |*compiled| compiled.deinit(self.allocator);
        }

        if (self.fact_arena) |arena_ptr| {
            arena_ptr.deinit();

            self.allocator.destroy(arena_ptr);
        }
    }

    pub fn prewarm(self: *Engine) !void {
        for (std.enums.values(language.Name)) |lang| {
            const compiled = try self.ensureCompiled(lang);

            try self.frontend.ensure(lang);

            if (needsMeasures(compiled)) _ = try self.ensureMetricQuery(lang.family());
        }

        _ = try self.ensureCompiledFact();
    }

    pub fn factRules(self: *const Engine) []const fact_rule.CompiledFactRule {
        return self.compiled_fact orelse &.{};
    }

    pub fn ensureCompiledFact(self: *Engine) ![]const fact_rule.CompiledFactRule {
        if (self.compiled_fact) |cached| return cached;

        const raws = self.rules.projectRaws();
        if (raws.len == 0) {
            self.compiled_fact = &.{};

            return self.compiled_fact.?;
        }

        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();

        const compiled = try self.compiler.compileFacts(arena_ptr.allocator(), raws, &self.compile_diag);

        self.fact_arena = arena_ptr;
        self.compiled_fact = compiled;

        return compiled;
    }

    /// prewarm and, on failure, write the compile diagnostic under "label"
    /// returns true when rules are ready, false when compilation failed
    ///
    /// every compile failure populates compile_diag before erroring, so an
    /// empty diag means an infrastructure failure that must propagate:
    /// reporting it would print an old or empty diagnostic.
    pub fn prewarmOrReport(self: *Engine, label: []const u8, stderr: *std.Io.Writer) !bool {
        self.compile_diag = .{};
        self.prewarm() catch |err| {
            if (self.compile_diag.detail.len == 0) return err;
            try self.compile_diag.write(label, stderr);

            return false;
        };

        return true;
    }

    fn ensureCompiled(self: *Engine, lang: language.Name) !?*rule.CompiledRule {
        const slot = self.compiled.getPtr(lang);
        switch (slot.*) {
            .compiled => |*cached| return cached,
            .none => return null,
            .not_compiled => {},
        }

        const compiled = (try self.compiler.compileLang(self.allocator, lang, self.rules.get(lang), &self.compile_diag)) orelse {
            slot.* = .none;
            return null;
        };
        slot.* = .{ .compiled = compiled };

        return &slot.compiled;
    }

    fn ensureMetricQuery(self: *Engine, fam: family_mod.Family) !*metric.Compiled {
        const slot = self.metric_queries.getPtr(fam);
        if (slot.*) |*cached| return cached;

        slot.* = try metric.compile(self.allocator, fam);

        return &slot.*.?;
    }

    pub fn extractFacts(
        self: *Engine,
        gpa: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: []const u8,
    ) !facts.FileFacts {
        var tree_ast = try self.frontend.tree(source, lang);
        defer tree_ast.deinit(self.allocator);

        return facts.extract(gpa, Node.fromKata(&tree_ast, tree_ast.root()), source, path, lang);
    }

    pub fn lint(
        self: *Engine,
        allocator: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: ?[]const u8,
    ) ![]diagnostic.Diagnostic {
        var tree_ast = try self.frontend.tree(source, lang);
        defer tree_ast.deinit(self.allocator);
        const root = Node.fromKata(&tree_ast, tree_ast.root());

        const compiled = try self.ensureCompiled(lang);

        var out: std.ArrayList(diagnostic.Diagnostic) = try .initCapacity(allocator, initial_diagnostic_capacity);
        errdefer out.deinit(allocator);

        const metric_ctx: ?matcher.MetricContext = if (needsMeasures(compiled)) .{
            .allocator = allocator,
            .compiled = try self.ensureMetricQuery(lang.family()),
            .fam = lang.family(),
        } else null;

        const eval_ctx: matcher.EvalContext = .{
            .allocator = allocator,
            .source = source,
            .root = root,
            .metric = metric_ctx,
        };

        if (compiled) |dsl| try runRule(allocator, dsl, eval_ctx, lang, self.settings, path, &out);

        return out.toOwnedSlice(allocator);
    }
};

fn needsMeasures(compiled: ?*rule.CompiledRule) bool {
    if (compiled) |dsl| return dsl.needs_measures;

    return false;
}

fn settingSeverity(
    settings: []const rule.RuleSetting,
    lang: language.Name,
    rule_id: []const u8,
) ?diagnostic.Severity {
    for (settings) |s| {
        if (s.matches(lang, rule_id)) return s.severity;
    }

    return null;
}

fn settingExcluded(
    settings: []const rule.RuleSetting,
    lang: language.Name,
    rule_id: []const u8,
    path: ?[]const u8,
) bool {
    for (settings) |s| {
        if (s.matches(lang, rule_id)) return pathExcluded(s.exclude, path);
    }

    return false;
}

pub fn runRule(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    ctx: matcher.EvalContext,
    lang: language.Name,
    settings: []const rule.RuleSetting,
    path: ?[]const u8,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const lang_str = lang.toString();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var eval_ctx = ctx;
    eval_ctx.allocator = scratch.allocator();

    for (r.patterns) |cp| {
        const match_id = cp.match_capture_id orelse continue;
        if (pathExcluded(cp.meta.exclude_paths, path)) continue;
        if (settingExcluded(settings, lang, cp.meta.rule_id, path)) continue;

        const severity = settingSeverity(settings, lang, cp.meta.rule_id) orelse cp.meta.severity;

        const matches = try query.run(scratch.allocator(), &cp.pattern, cp.capture_count, eval_ctx.root);
        for (matches) |match| {
            if (!try matcher.evaluate(cp.meta.predicates, match, eval_ctx)) continue;

            const message = if (cp.meta.message) |m| switch (m) {
                .plain => |text| text,
                .segments => |segments| try matcher.renderMessage(allocator, segments, match, eval_ctx),
            } else cp.meta.rule_id;

            try emitDiagnostic(allocator, match_id, cp.meta, match, lang_str, message, severity, out);
        }
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

fn emitDiagnostic(
    allocator: std.mem.Allocator,
    match_id: query.CaptureId,
    meta: rule.PatternMeta,
    match: query.Match,
    lang_str: []const u8,
    message: []const u8,
    severity: diagnostic.Severity,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const n = match.get(match_id) orelse return;
    const sp = n.startPoint();
    const ep = n.endPoint();

    try out.append(allocator, .{
        .rule_id = meta.rule_id,
        .language = lang_str,
        .message = message,
        .range = .{
            .start = .{ .line = sp.row, .column = sp.column },
            .end = .{ .line = ep.row, .column = ep.column },
        },
        .severity = severity,
    });
}

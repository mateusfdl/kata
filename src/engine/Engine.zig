const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const dispatch = @import("dispatch.zig");
const edits = @import("edits.zig");
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

/// caches the outcome of rule compilation per language. `none` (no kata-format
/// rules exist) must be remembered too, leaving the slot empty would re-scan
/// the raw rules on every lint call
const RuleSlot = union(enum) {
    not_compiled,
    none,
    compiled: rule.CompiledRule,
    failed: struct {
        compiled: ?rule.CompiledRule = null,
        diagnostic: rule.Diagnostic,
    },
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

    pub const FixPolicy = enum { safe, unsafe, declared };
    pub const FixStatus = enum { converged, syntax_error, pass_limit };

    pub const FixResult = struct {
        source: []const u8,
        diagnostics: []diagnostic.Diagnostic,
        rule_ids: []const []const u8,
        status: FixStatus,
        changed: bool,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        rules: *RuleSet,
        compiler: rule_compiler.RuleCompiler,
        settings: []const rule.RuleSetting,
    ) Engine {
        return .{
            .allocator = allocator,
            .rules = rules,
            .compiler = compiler,
            .frontend = parse.Frontend.init(allocator),
            .settings = settings,
        };
    }

    pub fn deinit(self: *Engine) void {
        var dit = self.compiled.iterator();
        while (dit.next()) |entry| {
            switch (entry.value.*) {
                .compiled => |*compiled| compiled.deinit(),
                .failed => |*failed| if (failed.compiled) |*compiled| compiled.deinit(),
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
            .failed => |failed| {
                self.compile_diag = failed.diagnostic;
                return error.CompileFailed;
            },
            .none => return null,
            .not_compiled => {},
        }

        const compiled_result = self.compiler.compileLang(self.allocator, lang, self.rules.get(lang), &self.compile_diag) catch |err| {
            if (err == error.CompileFailed and self.compile_diag.detail.len > 0) {
                slot.* = .{ .failed = .{ .diagnostic = self.compile_diag } };
            }
            return err;
        };
        var compiled = compiled_result orelse {
            slot.* = .none;
            return null;
        };

        const table = dispatch.Table.build(
            compiled.arena.allocator(),
            self.allocator,
            compiled.patterns,
            family_mod.of(lang.family()).kind_count,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                compiled.deinit();
                return error.OutOfMemory;
            },
            error.EmptyRootKinds => {
                self.compile_diag = .{
                    .lang = lang,
                    .rule_id = underivableRuleId(self.allocator, compiled.patterns),
                    .detail = "cannot derive root kinds",
                };
                slot.* = .{ .failed = .{
                    .compiled = compiled,
                    .diagnostic = self.compile_diag,
                } };
                return error.CompileFailed;
            },
        };
        compiled.dispatch = table;
        slot.* = .{ .compiled = compiled };

        return &slot.compiled;
    }

    fn underivableRuleId(allocator: std.mem.Allocator, patterns: []const rule.CompiledPattern) []const u8 {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        for (patterns) |cp| {
            _ = scratch.reset(.retain_capacity);
            _ = dispatch.rootKinds(scratch.allocator(), &cp.pattern) catch return cp.meta.rule_id;
        }
        return "";
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
        var parsed = try self.parseSource(source, lang);
        defer parsed.deinit();

        return self.extractFactsParsed(gpa, &parsed, path);
    }

    pub fn parseSource(self: *Engine, source: []const u8, lang: language.Name) !parse.Parsed {
        return self.frontend.parse(source, lang);
    }

    pub fn extractFactsParsed(
        self: *Engine,
        gpa: std.mem.Allocator,
        parsed: *const parse.Parsed,
        path: []const u8,
    ) !facts.FileFacts {
        _ = self;
        return facts.extract(gpa, Node.fromKata(&parsed.ast, parsed.ast.root()), parsed.source, path, parsed.lang);
    }

    pub fn lint(
        self: *Engine,
        allocator: std.mem.Allocator,
        source: []const u8,
        lang: language.Name,
        path: ?[]const u8,
    ) ![]diagnostic.Diagnostic {
        var parsed = try self.parseSource(source, lang);
        defer parsed.deinit();

        return self.lintParsed(allocator, &parsed, path);
    }

    pub fn lintParsed(
        self: *Engine,
        allocator: std.mem.Allocator,
        parsed: *const parse.Parsed,
        path: ?[]const u8,
    ) ![]diagnostic.Diagnostic {
        const root = Node.fromKata(&parsed.ast, parsed.ast.root());
        const source = parsed.source;
        const lang = parsed.lang;

        const compiled = try self.ensureCompiled(lang);

        var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
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

        std.mem.sort(diagnostic.Diagnostic, out.items, {}, diagnostic.lessThan);

        return out.toOwnedSlice(allocator);
    }

    pub fn fix(
        self: *Engine,
        arena: *std.heap.ArenaAllocator,
        source: []const u8,
        lang: language.Name,
        path: ?[]const u8,
        policy: FixPolicy,
    ) !FixResult {
        const allocator = arena.allocator();
        var current = source;
        var diagnostics = try self.lint(allocator, current, lang, path);
        var pass: usize = 0;

        while (pass < 8) : (pass += 1) {
            const applicable = try self.applicableFixes(allocator, lang, diagnostics, policy);
            if (applicable.fixes.len == 0) {
                return .{
                    .source = current,
                    .diagnostics = diagnostics,
                    .rule_ids = &.{},
                    .status = .converged,
                    .changed = !std.mem.eql(u8, source, current),
                };
            }

            const list = try edits.fromFixes(allocator, current, applicable.fixes);
            const applied = try edits.apply(allocator, current, list);
            var parsed = try self.parseSource(applied.source, lang);
            defer parsed.deinit();
            if (parsed.has_error) {
                return .{
                    .source = current,
                    .diagnostics = diagnostics,
                    .rule_ids = applicable.rule_ids,
                    .status = .syntax_error,
                    .changed = !std.mem.eql(u8, source, current),
                };
            }

            current = applied.source;
            diagnostics = try self.lintParsed(allocator, &parsed, path);
        }

        const remaining = try self.applicableFixes(allocator, lang, diagnostics, policy);
        return .{
            .source = current,
            .diagnostics = diagnostics,
            .rule_ids = remaining.rule_ids,
            .status = if (remaining.fixes.len == 0) .converged else .pass_limit,
            .changed = !std.mem.eql(u8, source, current),
        };
    }

    const ApplicableFixes = struct {
        fixes: []const diagnostic.Fix,
        rule_ids: []const []const u8,
    };

    fn applicableFixes(
        self: *const Engine,
        allocator: std.mem.Allocator,
        lang: language.Name,
        diagnostics: []const diagnostic.Diagnostic,
        policy: FixPolicy,
    ) !ApplicableFixes {
        var fixes: std.ArrayList(diagnostic.Fix) = .empty;
        var rule_ids: std.ArrayList([]const u8) = .empty;

        for (diagnostics) |item| {
            const fix_item = item.fix orelse continue;
            if (policy != .declared) {
                const override = self.fixOverride(lang, item.rule_id);
                if (override == .never) continue;
                if (fix_item.safety == .unsafe and policy != .unsafe and override != .unsafe_ok) continue;
            }

            try fixes.append(allocator, fix_item);
            if (!containsString(rule_ids.items, item.rule_id)) try rule_ids.append(allocator, item.rule_id);
        }

        return .{
            .fixes = try fixes.toOwnedSlice(allocator),
            .rule_ids = try rule_ids.toOwnedSlice(allocator),
        };
    }

    fn fixOverride(self: *const Engine, lang: language.Name, rule_id: []const u8) ?rule.FixMode {
        return rule.resolvePolicy(self.settings, .{ .language = lang }, rule_id, null).fix;
    }

    pub fn rulesWithFixes(self: *Engine, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            switch (entry.value.*) {
                .compiled => |*compiled| {
                    for (compiled.patterns) |cp| {
                        if (cp.meta.fix == null) continue;
                        if (containsString(out.items, cp.meta.rule_id)) continue;

                        try out.append(arena, cp.meta.rule_id);
                    }
                },
                else => {},
            }
        }

        return out.toOwnedSlice(arena);
    }
};

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }

    return false;
}

fn needsMeasures(compiled: ?*rule.CompiledRule) bool {
    if (compiled) |dsl| return dsl.needs_measures;

    return false;
}

const PatternRun = struct {
    match_id: query.CaptureId,
    severity: diagnostic.Severity,
};

/// walk the tree once, offering each node only to the patterns registered for
/// its kind in the rule set's dispatch table. diagnostics come out in source
/// position order (pre-order: enclosing node first), rule id order within a
/// node. requires `r.dispatch` to be built.
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

    var run_scratch = std.heap.ArenaAllocator.init(allocator);
    defer run_scratch.deinit();

    const runs = try run_scratch.allocator().alloc(?PatternRun, r.patterns.len);
    for (r.patterns, runs) |cp, *run| {
        run.* = patternRun(cp, lang, settings, path);
    }

    var match_scratch = std.heap.ArenaAllocator.init(allocator);
    defer match_scratch.deinit();

    var eval_scratch = std.heap.ArenaAllocator.init(allocator);
    defer eval_scratch.deinit();

    try dispatchTree(allocator, r, runs, ctx, lang_str, &match_scratch, &eval_scratch, out, ctx.root);
}

fn patternRun(
    cp: rule.CompiledPattern,
    lang: language.Name,
    settings: []const rule.RuleSetting,
    path: ?[]const u8,
) ?PatternRun {
    const match_id = cp.match_capture_id orelse return null;
    if (pathExcluded(cp.meta.exclude_paths, path)) return null;
    const policy = rule.resolvePolicy(settings, .{ .language = lang }, cp.meta.rule_id, path);
    if (!policy.enabled or policy.excluded) return null;

    return .{
        .match_id = match_id,
        .severity = policy.severity orelse cp.meta.severity,
    };
}

fn dispatchTree(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
    runs: []const ?PatternRun,
    ctx: matcher.EvalContext,
    lang_str: []const u8,
    match_scratch: *std.heap.ArenaAllocator,
    eval_scratch: *std.heap.ArenaAllocator,
    out: *std.ArrayList(diagnostic.Diagnostic),
    n: Node,
) !void {
    var nodes = n.preorder();
    while (nodes.next()) |candidate| {
        for (r.dispatch.slots[candidate.kindId()]) |pattern_index| {
            const run = runs[pattern_index] orelse continue;
            const cp = r.patterns[pattern_index];

            _ = match_scratch.reset(.retain_capacity);
            var sink: RuleSink = .{
                .allocator = allocator,
                .compiled = &cp,
                .run = run,
                .ctx = ctx,
                .lang_str = lang_str,
                .eval_scratch = eval_scratch,
                .out = out,
            };
            try query.streamAt(match_scratch.allocator(), &cp.pattern, cp.capture_count, candidate, &sink);
        }
    }
}

const RuleSink = struct {
    allocator: std.mem.Allocator,
    compiled: *const rule.CompiledPattern,
    run: PatternRun,
    ctx: matcher.EvalContext,
    lang_str: []const u8,
    eval_scratch: *std.heap.ArenaAllocator,
    out: *std.ArrayList(diagnostic.Diagnostic),
    done: bool = false,

    pub fn emit(self: *RuleSink, bindings: []const ?Node) std.mem.Allocator.Error!void {
        _ = self.eval_scratch.reset(.retain_capacity);
        var eval_ctx = self.ctx;
        eval_ctx.allocator = self.eval_scratch.allocator();
        var metric_cache: matcher.MetricCache = .{};
        if (eval_ctx.metric) |*metric_ctx| {
            metric_ctx.allocator = eval_ctx.allocator;
            metric_ctx.cache = &metric_cache;
        }
        const match: query.Match = .{ .nodes = bindings };
        if (!try matcher.evaluate(self.compiled.meta.predicates, match, eval_ctx)) return;

        const message = if (self.compiled.meta.message) |template|
            try renderTemplate(self.allocator, template, match, eval_ctx)
        else
            self.compiled.meta.rule_id;
        const fix = try renderFix(self.allocator, self.compiled.meta, match, eval_ctx);
        const suggestions = try renderSuggestions(self.allocator, self.compiled.meta, match, eval_ctx);
        try emitDiagnostic(
            self.allocator,
            self.run.match_id,
            self.compiled.meta,
            match,
            eval_ctx.source,
            self.lang_str,
            message,
            self.run.severity,
            fix,
            suggestions,
            self.out,
        );
    }
};

fn pathExcluded(globs: []const []const u8, path: ?[]const u8) bool {
    const p = path orelse return false;
    if (p.len == 0) return false;

    for (globs) |g| {
        if (glob.match(g, p)) return true;
    }

    return false;
}

fn renderTemplate(
    allocator: std.mem.Allocator,
    template: rule.Message,
    match: query.Match,
    ctx: matcher.EvalContext,
) ![]const u8 {
    return switch (template) {
        .plain => |text| text,
        .segments => |segments| try matcher.renderMessage(allocator, segments, match, ctx),
    };
}

fn renderFix(
    allocator: std.mem.Allocator,
    meta: rule.PatternMeta,
    match: query.Match,
    ctx: matcher.EvalContext,
) !?diagnostic.Fix {
    const fix = meta.fix orelse return null;
    const n = match.get(fix.target_id) orelse return null;

    return .{
        .range = n.range(),
        .replacement = try renderTemplate(allocator, fix.template, match, ctx),
        .safety = fix.safety,
    };
}

fn renderSuggestions(
    allocator: std.mem.Allocator,
    meta: rule.PatternMeta,
    match: query.Match,
    ctx: matcher.EvalContext,
) ![]const diagnostic.Suggestion {
    if (meta.suggestions.len == 0) return &.{};

    var out: std.ArrayList(diagnostic.Suggestion) = .empty;
    for (meta.suggestions) |suggestion| {
        const n = match.get(suggestion.target_id) orelse continue;
        try out.append(allocator, .{
            .label = suggestion.label,
            .range = n.range(),
            .replacement = try renderTemplate(allocator, suggestion.template, match, ctx),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn emitDiagnostic(
    allocator: std.mem.Allocator,
    match_id: query.CaptureId,
    meta: rule.PatternMeta,
    match: query.Match,
    source: []const u8,
    lang_str: []const u8,
    message: []const u8,
    severity: diagnostic.Severity,
    fix: ?diagnostic.Fix,
    suggestions: []const diagnostic.Suggestion,
    out: *std.ArrayList(diagnostic.Diagnostic),
) !void {
    const n = match.get(match_id) orelse return;
    const context = try enclosingContext(allocator, n, source);

    try out.append(allocator, .{
        .rule_id = meta.rule_id,
        .language = lang_str,
        .message = message,
        .range = n.range(),
        .severity = severity,
        .maturity = meta.maturity,
        .context = context,
        .fix = fix,
        .suggestions = suggestions,
    });
}

fn enclosingContext(allocator: std.mem.Allocator, node: Node, source: []const u8) ![]const diagnostic.Context {
    var entries: [4]diagnostic.Context = undefined;
    var count: usize = 0;
    var current = node.parent();

    while (current) |ancestor| : (current = ancestor.parent()) {
        const kind = family_mod.of(ancestor.tree.family).contextKind(ancestor.kindId()) orelse continue;
        entries[count] = .{
            .kind = kind,
            .name = try contextName(allocator, ancestor, source),
            .range = ancestor.range(),
        };
        count += 1;
        if (count == entries.len) break;

        if (kind == .method and ancestor.tree.family == .go) {
            if (try goReceiverContext(allocator, ancestor, source)) |receiver| {
                entries[count] = receiver;
                count += 1;
                if (count == entries.len) break;
            }
        }
    }

    if (count == 0) return &.{};

    const context = try allocator.alloc(diagnostic.Context, count);
    for (0..count) |index| context[index] = entries[count - index - 1];

    return context;
}

fn goReceiverContext(allocator: std.mem.Allocator, method: Node, source: []const u8) !?diagnostic.Context {
    const receiver = method.childByFieldName("receiver") orelse return null;
    const parameter = receiver.namedChild(0) orelse return null;
    const receiver_type = parameter.childByFieldName("type") orelse return null;
    const name_node = findNamedKind(receiver_type, "type_identifier") orelse receiver_type;
    const name = name_node.text(source) orelse return null;

    return .{
        .kind = .class,
        .name = try allocator.dupe(u8, name),
        .range = receiver_type.range(),
    };
}

fn findNamedKind(node: Node, kind: []const u8) ?Node {
    var nodes = node.preorder();
    while (nodes.next()) |candidate| {
        if (std.mem.eql(u8, candidate.kind(), kind)) return candidate;
    }

    return null;
}

fn contextName(allocator: std.mem.Allocator, node: Node, source: []const u8) ![]const u8 {
    if (node.childByFieldName("name")) |name| {
        if (name.text(source)) |text| return allocator.dupe(u8, text);
    }

    if (node.parent()) |parent| {
        if (std.mem.eql(u8, parent.kind(), "variable_declarator")) {
            if (parent.childByFieldName("name")) |name| {
                if (name.text(source)) |text| return allocator.dupe(u8, text);
            }
        }
    }

    if (node.namedChild(0)) |first_child| {
        if (first_child.childByFieldName("name")) |name| {
            if (name.text(source)) |text| return allocator.dupe(u8, text);
        }
    }

    return allocator.dupe(u8, "<anonymous>");
}

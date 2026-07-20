const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const dispatch = @import("dispatch.zig");
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

        const table = dispatch.Table.build(
            slot.compiled.arena.allocator(),
            slot.compiled.patterns,
            family_mod.of(lang.family()).kind_count,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyRootKinds => {
                self.compile_diag = .{
                    .lang = lang,
                    .rule_id = underivableRuleId(slot.compiled.arena.allocator(), slot.compiled.patterns),
                    .detail = "cannot derive root kinds",
                };
                return error.CompileFailed;
            },
        };
        slot.compiled.dispatch = table;

        return &slot.compiled;
    }

    fn underivableRuleId(arena: std.mem.Allocator, patterns: []const rule.CompiledPattern) []const u8 {
        for (patterns) |cp| {
            _ = dispatch.rootKinds(arena, &cp.pattern) catch return cp.meta.rule_id;
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

    pub fn hasSyntaxError(self: *Engine, source: []const u8, lang: language.Name) !bool {
        return self.frontend.hasError(source, lang);
    }

    pub fn fixOverride(self: *const Engine, lang: language.Name, rule_id: []const u8) ?rule.FixMode {
        for (self.settings) |setting| {
            if (setting.matches(lang, rule_id)) return setting.fix;
        }

        return null;
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

            const message = if (cp.meta.message) |m| try renderTemplate(allocator, m, match, eval_ctx) else cp.meta.rule_id;
            const fix = try renderFix(allocator, cp.meta, match, eval_ctx);
            const suggestions = try renderSuggestions(allocator, cp.meta, match, eval_ctx);

            try emitDiagnostic(allocator, match_id, cp.meta, match, eval_ctx.source, lang_str, message, severity, fix, suggestions, out);
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
        .range = nodeRange(n),
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
            .range = nodeRange(n),
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
        .range = nodeRange(n),
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
            .range = nodeRange(ancestor),
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
        .range = nodeRange(receiver_type),
    };
}

fn findNamedKind(node: Node, kind: []const u8) ?Node {
    if (std.mem.eql(u8, node.kind(), kind)) return node;

    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        const child = node.namedChild(index).?;
        if (findNamedKind(child, kind)) |match| return match;
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

fn nodeRange(node: Node) diagnostic.Range {
    const start = node.startPoint();
    const end = node.endPoint();

    return .{
        .start = .{ .line = start.row, .column = start.column },
        .end = .{ .line = end.row, .column = end.column },
    };
}

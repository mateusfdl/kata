const std = @import("std");
const ts = @import("tree_sitter");

const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");
const loader = @import("loader.zig");
const rule = @import("rule.zig");

const initial_diagnostic_capacity: usize = 16;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    rules: *loader.RuleSet,
    compiled: std.EnumArray(language.Name, ?[]rule.CompiledRule) = .initFill(null),

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *language.Registry,
        rules: *loader.RuleSet,
    ) Engine {
        return .{
            .allocator = allocator,
            .registry = registry,
            .rules = rules,
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            if (entry.value.*) |compiled| {
                rule.destroyCompiled(self.allocator, compiled);
                entry.value.* = null;
            }
        }
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
        if (rules.len == 0) return allocator.alloc(diagnostic.Diagnostic, 0);

        const ts_lang = self.registry.get(lang);
        const tree = try parseSource(ts_lang, source);
        defer tree.destroy();

        var out: std.ArrayList(diagnostic.Diagnostic) = try .initCapacity(allocator, initial_diagnostic_capacity);
        errdefer out.deinit(allocator);

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        for (rules) |*r| {
            try runRule(allocator, r, cursor, tree.rootNode(), source, lang, &out);
        }

        return out.toOwnedSlice(allocator);
    }
};

fn parseSource(ts_lang: *const ts.Language, source: []const u8) !*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(ts_lang) catch return error.SetLanguageFailed;
    return parser.parseString(source, null) orelse error.ParseFailed;
}

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
        if (!evaluatePredicates(meta.predicates, match, source)) continue;

        const message = meta.message orelse r.id;
        try emitMatchDiagnostics(allocator, r, match, lang_str, message, out);
    }
}

fn emitMatchDiagnostics(
    allocator: std.mem.Allocator,
    r: *const rule.CompiledRule,
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
            .rule_id = r.id,
            .language = lang_str,
            .severity = diagnostic.severity_error,
            .message = message,
            .range = .{
                .start = .{ .line = sp.row, .column = sp.column },
                .end = .{ .line = ep.row, .column = ep.column },
            },
        });
    }
}

fn evaluatePredicates(
    predicates: []const rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
) bool {
    for (predicates) |pred| {
        switch (pred.op) {
            .eq => if (!evalEq(pred, match, source, false)) return false,
            .not_eq => if (!evalEq(pred, match, source, true)) return false,
            .any_of => if (!evalAnyOf(pred, match, source, false)) return false,
            .not_any_of => if (!evalAnyOf(pred, match, source, true)) return false,
            .unknown => {},
        }
    }
    return true;
}

fn evalEq(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len != 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    const right_text = resolveText(pred.args[1], match, source) orelse return false;
    const eq = std.mem.eql(u8, left_text, right_text);
    return if (negate) !eq else eq;
}

fn evalAnyOf(
    pred: rule.Predicate,
    match: ts.Query.Match,
    source: []const u8,
    negate: bool,
) bool {
    if (pred.args.len < 2) return false;
    const left_text = resolveText(pred.args[0], match, source) orelse return false;
    for (pred.args[1..]) |arg| {
        const candidate = resolveText(arg, match, source) orelse continue;
        if (std.mem.eql(u8, left_text, candidate)) return if (negate) false else true;
    }
    return if (negate) true else false;
}

fn resolveText(
    operand: rule.PredicateOperand,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    return switch (operand) {
        .string => |s| s,
        .capture => |id| findCaptureText(id, match, source),
    };
}

fn findCaptureText(
    id: u32,
    match: ts.Query.Match,
    source: []const u8,
) ?[]const u8 {
    for (match.captures) |cap| {
        if (cap.index != id) continue;
        const start = cap.node.startByte();
        const end = cap.node.endByte();
        if (end > source.len) return null;
        return source[start..end];
    }
    return null;
}

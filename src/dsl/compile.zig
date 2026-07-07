const std = @import("std");
const mvzr = @import("mvzr");
const ts = @import("tree_sitter");

const ast = @import("ast.zig");
const diagnostic = @import("../lint/diagnostic.zig");
const dsl_parser = @import("parser.zig");
const expr = @import("../lint/expr.zig");
const language = @import("../lint/language.zig");
const rule = @import("../lint/rule.zig");

pub const Error = error{
    OutOfMemory,
    QueryCompileFailed,
    UnknownLanguage,
    UnsupportedMatch,
    UnsupportedPredicate,
    UnsupportedPlaceholder,
    UnknownCapture,
    UnknownMeasure,
    EmitCaptureConflict,
    InvalidRegex,
    InvalidStringComparison,
    ReservedCapture,
};

pub const RawError = Error || dsl_parser.Error || error{
    RuleIdMismatch,
    UndeclaredLanguage,
    ProjectRuleInLocalDir,
};

const Cardinality = enum { one, many };

const nested_root_capture = "kata-nested-root";

const Compiler = struct {
    arena: std.mem.Allocator,
    lang: language.Name,
    diag: *rule.Diagnostic,
    registry: *language.Registry,
    rule_id: []const u8 = "",
    query: *ts.Query = undefined,
    nested_queries: std.ArrayList(*ts.Query) = .empty,

    fn fail(self: *Compiler, detail: []const u8) void {
        self.diag.* = .{ .lang = self.lang, .rule_id = self.rule_id, .detail = detail };
    }
};

pub fn compileRaws(
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    lang: language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) RawError!?rule.CompiledRule {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var rules: std.ArrayList(ast.Rule) = .empty;
    for (raws) |raw| {
        if (raw.format != .kata) continue;
        try rules.appendSlice(arena, try parseRaw(arena, lang, raw, diag));
    }
    if (rules.items.len == 0) return null;

    return try compile(allocator, registry, lang, .{ .rules = rules.items }, diag);
}

fn parseRaw(
    arena: std.mem.Allocator,
    lang: language.Name,
    raw: rule.RawRule,
    diag: *rule.Diagnostic,
) RawError![]const ast.Rule {
    var parse_diag: dsl_parser.Diagnostic = .{};
    const file = parseSource(arena, raw.source, &parse_diag) catch |err| {
        diag.* = .{
            .lang = lang,
            .rule_id = raw.id,
            .detail = "invalid rule syntax",
            .line = parse_diag.line,
            .column = parse_diag.column,
        };
        return err;
    };
    for (file.rules) |r| {
        if (r.kind == .project) {
            diag.* = .{ .lang = lang, .rule_id = raw.id, .detail = "project rules are not supported yet" };
            return error.ProjectRuleInLocalDir;
        }
        if (!std.mem.eql(u8, r.id, raw.id)) {
            diag.* = .{ .lang = lang, .rule_id = raw.id, .detail = "rule id does not match the file name" };
            return error.RuleIdMismatch;
        }
        if (!includesLanguage(r, lang)) {
            diag.* = .{ .lang = lang, .rule_id = raw.id, .detail = "rule does not declare this language" };
            return error.UndeclaredLanguage;
        }
    }
    return file.rules;
}

fn parseSource(
    arena: std.mem.Allocator,
    source: []const u8,
    parse_diag: *dsl_parser.Diagnostic,
) dsl_parser.Error!ast.File {
    var p = try dsl_parser.Parser.init(arena, source, parse_diag);
    return p.parseFile();
}

pub fn compile(
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    lang: language.Name,
    file: ast.File,
    diag: *rule.Diagnostic,
) Error!rule.CompiledRule {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var ctx: Compiler = .{ .arena = arena, .lang = lang, .diag = diag, .registry = registry };
    errdefer for (ctx.nested_queries.items) |nested| nested.destroy();

    var selected: std.ArrayList(*const ast.Rule) = .empty;
    var starts: std.ArrayList(u32) = .empty;
    var query_source: std.ArrayList(u8) = .empty;

    for (file.rules) |*r| {
        ctx.rule_id = r.id;
        try validateLanguages(&ctx, r.*);
        if (r.kind == .project) continue;
        if (!includesLanguage(r.*, lang)) continue;
        try starts.append(arena, @intCast(query_source.items.len));
        try selected.append(arena, r);
        try renderPattern(&ctx, &query_source, r.*);
        try query_source.append(arena, '\n');
    }

    var error_offset: u32 = 0;
    const query = ts.Query.create(registry.get(lang), query_source.items, &error_offset) catch {
        ctx.rule_id = owningRuleId(starts.items, selected.items, error_offset);
        ctx.fail("node kind or field is invalid for the grammar");
        return error.QueryCompileFailed;
    };
    errdefer query.destroy();

    if (query.patternCount() != selected.items.len) {
        ctx.fail("match compiled to an unexpected pattern count");
        return error.QueryCompileFailed;
    }
    ctx.query = query;

    const patterns = try arena.alloc(rule.PatternMeta, selected.items.len);
    for (selected.items, patterns) |r, *meta| {
        ctx.rule_id = r.id;
        meta.* = try compilePattern(&ctx, r.*);
    }

    return .{
        .language = lang,
        .query = query,
        .patterns = patterns,
        .match_capture_id = rule.captureIdForName(query, rule.match_capture),
        .needs_measures = rule.needsMeasures(patterns),
        .nested_queries = ctx.nested_queries.items,
        .arena = arena_ptr,
        .allocator = allocator,
    };
}

fn validateLanguages(ctx: *Compiler, r: ast.Rule) Error!void {
    for (r.languages) |name| {
        if (language.Name.fromString(name) == null) {
            ctx.fail("unknown language");
            return error.UnknownLanguage;
        }
    }
}

fn includesLanguage(r: ast.Rule, lang: language.Name) bool {
    for (r.languages) |name| {
        if (language.Name.fromString(name)) |resolved| {
            if (resolved == lang) return true;
        }
    }
    return false;
}

fn owningRuleId(starts: []const u32, rules: []const *const ast.Rule, offset: u32) []const u8 {
    if (rules.len == 0) return "";
    var i: usize = starts.len;
    while (i > 0) {
        i -= 1;
        if (starts[i] <= offset) return rules[i].id;
    }
    return rules[0].id;
}

fn renderPattern(ctx: *Compiler, out: *std.ArrayList(u8), r: ast.Rule) Error!void {
    const pattern = switch (r.match.?) {
        .node => |node| node,
        .kind => {
            ctx.fail("match kind is not supported yet");
            return error.UnsupportedMatch;
        },
    };
    const emit_name = r.emit.capture.name;
    if (!captureExists(pattern, emit_name)) {
        ctx.fail("emit capture not found in match");
        return error.UnknownCapture;
    }
    if (!std.mem.eql(u8, emit_name, rule.match_capture) and captureExists(pattern, rule.match_capture)) {
        ctx.fail("rule emits another capture but also binds @match");
        return error.EmitCaptureConflict;
    }
    try renderNode(ctx, out, pattern, emit_name, .one);
}

fn captureExists(pattern: ast.NodePattern, name: []const u8) bool {
    if (pattern.capture) |capture| {
        if (std.mem.eql(u8, capture.name, name)) return true;
    }
    for (pattern.fields) |field| {
        if (captureExists(field.pattern, name)) return true;
    }
    return false;
}

fn renderNode(
    ctx: *Compiler,
    out: *std.ArrayList(u8),
    pattern: ast.NodePattern,
    emit_name: []const u8,
    cardinality: Cardinality,
) Error!void {
    switch (pattern.node_kind) {
        .symbol => |kind| try renderBranch(ctx, out, kind, pattern.fields, emit_name),
        .anonymous => |token| {
            if (pattern.fields.len != 0) {
                ctx.fail("anonymous tokens cannot have child patterns");
                return error.UnsupportedMatch;
            }
            try out.append(ctx.arena, '"');
            for (token) |c| {
                if (c == '"' or c == '\\') try out.append(ctx.arena, '\\');
                try out.append(ctx.arena, c);
            }
            try out.append(ctx.arena, '"');
        },
        .alternation => |kinds| {
            try out.append(ctx.arena, '[');
            for (kinds, 0..) |kind, i| {
                if (i > 0) try out.append(ctx.arena, ' ');
                try renderBranch(ctx, out, kind, pattern.fields, emit_name);
            }
            try out.append(ctx.arena, ']');
        },
    }
    if (cardinality == .many) try out.append(ctx.arena, '*');
    if (pattern.capture) |capture| {
        try out.appendSlice(ctx.arena, " @");
        try out.appendSlice(ctx.arena, capture.name);
        if (std.mem.eql(u8, capture.name, emit_name) and !std.mem.eql(u8, emit_name, rule.match_capture)) {
            try out.appendSlice(ctx.arena, " @");
            try out.appendSlice(ctx.arena, rule.match_capture);
        }
    }
}

fn renderBranch(
    ctx: *Compiler,
    out: *std.ArrayList(u8),
    kind: []const u8,
    fields: []const ast.FieldPattern,
    emit_name: []const u8,
) Error!void {
    try out.append(ctx.arena, '(');
    try out.appendSlice(ctx.arena, kind);
    for (fields) |field| {
        try out.append(ctx.arena, ' ');
        switch (field.relation) {
            .field => |name| {
                try out.appendSlice(ctx.arena, name);
                try out.appendSlice(ctx.arena, ": ");
            },
            .child, .children => {},
        }
        const child_cardinality: Cardinality = if (field.relation == .children) .many else .one;
        try renderNode(ctx, out, field.pattern, emit_name, child_cardinality);
    }
    try out.append(ctx.arena, ')');
}

fn compilePattern(ctx: *Compiler, r: ast.Rule) Error!rule.PatternMeta {
    var predicates: std.ArrayList(rule.Predicate) = .empty;
    for (r.where) |predicate| {
        try translatePredicate(ctx, predicate, &predicates);
    }
    return .{
        .predicates = try predicates.toOwnedSlice(ctx.arena),
        .message = try compileMessage(ctx, r.emit.message),
        .rule_id = try ctx.arena.dupe(u8, r.id),
        .exclude_paths = try dupeAll(ctx.arena, r.exclude_paths),
        .severity = switch (r.severity) {
            .@"error" => .@"error",
            .warn => .warn,
        },
    };
}

fn dupeAll(arena: std.mem.Allocator, items: []const []const u8) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try arena.dupe(u8, item);
    return out;
}

fn translatePredicate(
    ctx: *Compiler,
    predicate: ast.Predicate,
    out: *std.ArrayList(rule.Predicate),
) Error!void {
    switch (predicate) {
        .expression => |expression| try translateExpression(ctx, expression, out),
        .composition => |composition| try out.append(ctx.arena, try compositionPredicate(ctx, composition)),
        .count => |count| try out.append(ctx.arena, try countPredicate(ctx, count)),
    }
}

fn compositionPredicate(ctx: *Compiler, composition: ast.Composition) Error!rule.Predicate {
    const op: rule.PredicateOp = switch (composition.op) {
        .inside => if (composition.negated) .not_inside else .inside,
        .has => if (composition.negated) .not_has else .has,
    };
    return .{
        .op = op,
        .args = try subjectArgs(ctx, composition.matcher),
        .nested = try compileNestedMatcher(ctx, composition.matcher),
    };
}

fn countPredicate(ctx: *Compiler, count: ast.CountPredicate) Error!rule.Predicate {
    return .{
        .op = .count,
        .args = try subjectArgs(ctx, count.matcher),
        .nested = try compileNestedMatcher(ctx, count.matcher),
        .count = .{ .op = compareOp(count.op), .value = count.value },
    };
}

fn subjectArgs(ctx: *Compiler, matcher: ast.NestedMatcher) Error![]rule.PredicateOperand {
    const args = try ctx.arena.alloc(rule.PredicateOperand, 1);
    args[0] = .{ .capture = try resolveCapture(ctx, matcher.subject.name) };
    return args;
}

fn compileNestedMatcher(ctx: *Compiler, matcher: ast.NestedMatcher) Error!*const rule.NestedMatcher {
    if (captureExists(matcher.pattern, nested_root_capture)) {
        ctx.fail(nested_root_capture ++ " is a reserved capture");
        return error.ReservedCapture;
    }

    var source: std.ArrayList(u8) = .empty;
    try renderNode(ctx, &source, matcher.pattern, "", .one);
    if (matcher.pattern.capture == null) {
        try source.appendSlice(ctx.arena, " @" ++ nested_root_capture);
    }

    var error_offset: u32 = 0;
    const query = ts.Query.create(ctx.registry.get(ctx.lang), source.items, &error_offset) catch {
        ctx.fail("node kind or field is invalid for the grammar");
        return error.QueryCompileFailed;
    };
    try ctx.nested_queries.append(ctx.arena, query);

    const root_name = if (matcher.pattern.capture) |capture| capture.name else nested_root_capture;

    var nested_ctx = ctx.*;
    nested_ctx.query = query;
    var predicates: std.ArrayList(rule.Predicate) = .empty;
    for (matcher.where) |expression| {
        try translateExpression(&nested_ctx, expression, &predicates);
    }

    const out = try ctx.arena.create(rule.NestedMatcher);
    out.* = .{
        .query = query,
        .root_capture_id = rule.captureIdForName(query, root_name),
        .predicates = try predicates.toOwnedSlice(ctx.arena),
    };
    return out;
}

fn translateExpression(
    ctx: *Compiler,
    expression: ast.Expression,
    out: *std.ArrayList(rule.Predicate),
) Error!void {
    if (expression == .logical and expression.logical.op == .@"and") {
        try translateExpression(ctx, expression.logical.left.*, out);
        try translateExpression(ctx, expression.logical.right.*, out);
        return;
    }
    if (try stringPredicate(ctx, expression, false)) |pred| {
        try out.append(ctx.arena, pred);
        return;
    }
    if (try numericExpression(ctx, expression)) |value| {
        const pointer = try ctx.arena.create(expr.Expr);
        pointer.* = value;
        try out.append(ctx.arena, .{
            .op = .where,
            .args = try ctx.arena.alloc(rule.PredicateOperand, 0),
            .where = pointer,
        });
        return;
    }
    ctx.fail("unsupported where expression");
    return error.UnsupportedPredicate;
}

fn stringPredicate(ctx: *Compiler, expression: ast.Expression, negated: bool) Error!?rule.Predicate {
    return switch (expression) {
        .negate => |negate| stringPredicate(ctx, negate.expression.*, !negated),
        .call => |call| callPredicate(ctx, call, negated),
        .compare => |c| comparePredicate(ctx, c, negated),
        .logical => |logical| if (logical.op == .@"or") anyOfPredicate(ctx, expression, negated) else null,
        else => null,
    };
}

fn anyOfPredicate(ctx: *Compiler, expression: ast.Expression, negated: bool) Error!?rule.Predicate {
    var capture: ?u32 = null;
    var strings: std.ArrayList([]const u8) = .empty;
    if (!try collectDisjunction(ctx, expression, &capture, &strings)) return null;

    const args = try ctx.arena.alloc(rule.PredicateOperand, strings.items.len + 1);
    args[0] = .{ .capture = capture.? };
    for (strings.items, args[1..]) |s, *slot| slot.* = .{ .string = s };
    return .{ .op = if (negated) .not_any_of else .any_of, .args = args };
}

fn collectDisjunction(
    ctx: *Compiler,
    expression: ast.Expression,
    capture: *?u32,
    strings: *std.ArrayList([]const u8),
) Error!bool {
    switch (expression) {
        .logical => |logical| {
            if (logical.op != .@"or") return false;
            if (!try collectDisjunction(ctx, logical.left.*, capture, strings)) return false;
            return collectDisjunction(ctx, logical.right.*, capture, strings);
        },
        .compare => |c| {
            if (c.op != .eq) return false;
            const left = (try textOperand(ctx, c.left.*)) orelse return false;
            const right = (try textOperand(ctx, c.right.*)) orelse return false;
            const leaf_capture = switch (left) {
                .capture => |id| id,
                .string => switch (right) {
                    .capture => |id| id,
                    .string => return false,
                },
            };
            const leaf_string = switch (left) {
                .string => |s| s,
                .capture => switch (right) {
                    .string => |s| s,
                    .capture => return false,
                },
            };
            if (capture.*) |seen| {
                if (seen != leaf_capture) return false;
            } else {
                capture.* = leaf_capture;
            }
            try strings.append(ctx.arena, leaf_string);
            return true;
        },
        else => return false,
    }
}

fn callPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    if (std.mem.eql(u8, call.name, "matches")) return matchesPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "capture")) return capturedPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "glob")) return globPredicate(ctx, call, negated);
    if (stringHelperOp(call.name, negated)) |op| return stringHelperPredicate(ctx, call, op);
    return null;
}

fn globPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    const fail_detail = "glob expects (value, \"pattern\")";
    if (call.args.len != 2 or call.args[1] != .string) {
        ctx.fail(fail_detail);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.fail(fail_detail);
        return error.UnsupportedPredicate;
    };
    const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
    args[0] = subject;
    args[1] = .{ .string = try ctx.arena.dupe(u8, call.args[1].string.value) };
    return .{ .op = if (negated) .not_glob else .glob, .args = args };
}

fn capturedPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    if (call.args.len != 1 or call.args[0] != .capture) {
        ctx.fail("capture expects one capture argument");
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(rule.PredicateOperand, 1);
    args[0] = .{ .capture = try resolveCapture(ctx, call.args[0].capture.name) };
    return .{ .op = if (negated) .not_captured else .captured, .args = args };
}

fn stringHelperOp(name: []const u8, negated: bool) ?rule.PredicateOp {
    if (std.mem.eql(u8, name, "startsWith")) return if (negated) .not_starts_with else .starts_with;
    if (std.mem.eql(u8, name, "endsWith")) return if (negated) .not_ends_with else .ends_with;
    if (std.mem.eql(u8, name, "contains")) return if (negated) .not_contains else .contains;
    return null;
}

fn stringHelperPredicate(ctx: *Compiler, call: ast.Call, op: rule.PredicateOp) Error!?rule.Predicate {
    if (call.args.len != 2) {
        ctx.fail("startsWith, endsWith, and contains expect (value, text)");
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.fail("startsWith, endsWith, and contains expect (value, text)");
        return error.UnsupportedPredicate;
    };
    const candidate = (try textOperand(ctx, call.args[1])) orelse {
        ctx.fail("startsWith, endsWith, and contains expect (value, text)");
        return error.UnsupportedPredicate;
    };
    const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
    args[0] = subject;
    args[1] = candidate;
    return .{ .op = op, .args = args };
}

fn matchesPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    if (!std.mem.eql(u8, call.name, "matches")) return null;
    if (call.args.len != 2) {
        ctx.fail("matches expects (value, regex)");
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.fail("matches expects a text value");
        return error.UnsupportedPredicate;
    };
    const pattern = switch (call.args[1]) {
        .string => |s| try ctx.arena.dupe(u8, s.value),
        else => {
            ctx.fail("matches expects a string regex");
            return error.UnsupportedPredicate;
        },
    };
    const regex = mvzr.compile(pattern) orelse {
        ctx.fail("invalid regex");
        return error.InvalidRegex;
    };
    const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
    args[0] = subject;
    args[1] = .{ .string = pattern };
    return .{
        .op = if (negated) .not_match else .match,
        .args = args,
        .regex = regex,
    };
}

fn comparePredicate(ctx: *Compiler, c: ast.Compare, negated: bool) Error!?rule.Predicate {
    const left = try textOperand(ctx, c.left.*);
    const right = try textOperand(ctx, c.right.*);
    if (c.op == .eq or c.op == .ne) {
        const resolved_left = left orelse return null;
        const resolved_right = right orelse return null;
        const wants_eq = (c.op == .eq) != negated;
        const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
        args[0] = resolved_left;
        args[1] = resolved_right;
        return .{ .op = if (wants_eq) .eq else .not_eq, .args = args };
    }
    if (left != null or right != null) {
        ctx.fail("strings compare with == and != only");
        return error.InvalidStringComparison;
    }
    return null;
}

fn textOperand(ctx: *Compiler, expression: ast.Expression) Error!?rule.PredicateOperand {
    switch (expression) {
        .string => |s| return .{ .string = try ctx.arena.dupe(u8, s.value) },
        .call => |call| {
            if (!std.mem.eql(u8, call.name, "text")) return null;
            if (call.args.len != 1 or call.args[0] != .capture) {
                ctx.fail("text expects one capture argument");
                return error.UnsupportedPredicate;
            }
            return .{ .capture = try resolveCapture(ctx, call.args[0].capture.name) };
        },
        else => return null,
    }
}

fn numericExpression(ctx: *Compiler, expression: ast.Expression) Error!?expr.Expr {
    switch (expression) {
        .compare => |c| {
            const left = (try numericTerm(ctx, c.left.*)) orelse return null;
            const right = (try numericTerm(ctx, c.right.*)) orelse return null;
            return .{ .compare = .{ .op = compareOp(c.op), .left = left, .right = right } };
        },
        .logical => |logical| {
            const left = (try numericExpression(ctx, logical.left.*)) orelse return null;
            const right = (try numericExpression(ctx, logical.right.*)) orelse return null;
            const items = try ctx.arena.alloc(expr.Expr, 2);
            items[0] = left;
            items[1] = right;
            return switch (logical.op) {
                .@"and" => .{ .all = items },
                .@"or" => .{ .any = items },
            };
        },
        .negate => |negate| {
            const inner = (try numericExpression(ctx, negate.expression.*)) orelse return null;
            const pointer = try ctx.arena.create(expr.Expr);
            pointer.* = inner;
            return .{ .negate = pointer };
        },
        else => return null,
    }
}

fn numericTerm(ctx: *Compiler, expression: ast.Expression) Error!?expr.Term {
    switch (expression) {
        .number => |n| return .{ .number = n.value },
        .call => |call| {
            const measure = numericMeasure(call.name) orelse {
                if (deferredPredicate(call.name)) return null;
                ctx.fail("unknown measure");
                return error.UnknownMeasure;
            };
            if (call.args.len != 1 or call.args[0] != .capture) {
                ctx.fail("measures expect one capture argument");
                return error.UnsupportedPredicate;
            }
            return .{ .measure = .{
                .measure = measure,
                .capture_id = try resolveCapture(ctx, call.args[0].capture.name),
            } };
        },
        else => return null,
    }
}

fn numericMeasure(name: []const u8) ?expr.Measure {
    const measure = expr.Measure.fromString(name) orelse return null;
    return if (measure == .text) null else measure;
}

fn deferredPredicate(name: []const u8) bool {
    const names = [_][]const u8{ "text", "matches", "startsWith", "endsWith", "contains", "capture" };
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn compareOp(op: ast.CompareOp) expr.Compare {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .gt => .gt,
        .ge => .ge,
        .lt => .lt,
        .le => .le,
    };
}

fn resolveCapture(ctx: *Compiler, name: []const u8) Error!u32 {
    const id = rule.captureIdForName(ctx.query, name);
    if (id == rule.invalid_capture_id) {
        ctx.fail("unknown capture");
        return error.UnknownCapture;
    }

    return id;
}

fn compileMessage(ctx: *Compiler, message: []const u8) Error!rule.Message {
    const segments = (try messageSegments(ctx, message)) orelse
        return .{ .plain = try ctx.arena.dupe(u8, message) };

    if (segments.len == 1 and segments[0] == .literal) return .{ .plain = segments[0].literal };

    return .{ .segments = segments };
}

fn messageSegments(ctx: *Compiler, message: []const u8) Error!?[]const rule.MessageSegment {
    if (std.mem.indexOfAny(u8, message, "{}") == null) return null;

    var segments: std.ArrayList(rule.MessageSegment) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < message.len) {
        const c = message[i];
        if (c == '{') {
            if (i + 1 < message.len and message[i + 1] == '{') {
                try literal.append(ctx.arena, '{');
                i += 2;
                continue;
            }

            const close = std.mem.indexOfScalarPos(u8, message, i + 1, '}') orelse
                return failPlaceholder(ctx);

            if (literal.items.len > 0)
                try segments.append(ctx.arena, .{ .literal = try literal.toOwnedSlice(ctx.arena) });
            try segments.append(ctx.arena, .{ .placeholder = try parsePlaceholder(ctx, message[i + 1 .. close]) });
            i = close + 1;
            continue;
        }
        if (c == '}') {
            if (i + 1 < message.len and message[i + 1] == '}') {
                try literal.append(ctx.arena, '}');
                i += 2;
                continue;
            }

            return failPlaceholder(ctx);
        }

        try literal.append(ctx.arena, c);
        i += 1;
    }

    if (literal.items.len > 0)
        try segments.append(ctx.arena, .{ .literal = try literal.toOwnedSlice(ctx.arena) });

    return try segments.toOwnedSlice(ctx.arena);
}

fn parsePlaceholder(ctx: *Compiler, inner: []const u8) Error!rule.Placeholder {
    const open = std.mem.indexOfScalar(u8, inner, '(') orelse return failPlaceholder(ctx);
    if (inner.len == 0 or inner[inner.len - 1] != ')') return failPlaceholder(ctx);

    const name = inner[0..open];
    const arg = inner[open + 1 .. inner.len - 1];

    if (arg.len < 2 or arg[0] != '@') return failPlaceholder(ctx);

    const measure = expr.Measure.fromString(name) orelse return failPlaceholder(ctx);

    return .{ .measure = measure, .capture_id = try resolveCapture(ctx, arg[1..]) };
}

fn failPlaceholder(ctx: *Compiler) Error {
    ctx.fail("message placeholder must be {<measure>(@capture)}");
    return error.UnsupportedPlaceholder;
}

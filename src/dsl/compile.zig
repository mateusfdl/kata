const std = @import("std");
const mvzr = @import("mvzr");

const ast = @import("ast.zig");
const lower = @import("lower.zig");
const diagnostic = @import("../lint/diagnostic.zig");
const dsl_parser = @import("parser.zig");
const expr = @import("../lint/expr.zig");
const language = @import("../lint/language.zig");
const query = @import("../lint/query.zig");
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
    EmitCaptureMissingInBranch,
    InvalidRegex,
    InvalidStringComparison,
    ReservedCapture,
};

pub const RawError = Error || dsl_parser.Error || error{
    RuleIdMismatch,
    UndeclaredLanguage,
    ProjectRuleInLocalDir,
};

const nested_root_capture = "kata-nested-root";

const Compiler = struct {
    arena: std.mem.Allocator,
    lang: language.Name,
    diag: *rule.Diagnostic,
    rule_id: []const u8 = "",
    captures: []const []const u8 = &.{},

    fn fail(self: *Compiler, detail: []const u8) void {
        self.diag.* = .{ .lang = self.lang, .rule_id = self.rule_id, .detail = detail };
    }
};

pub fn compileRaws(
    allocator: std.mem.Allocator,
    lang: language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) RawError!?rule.CompiledRule {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var rules: std.ArrayList(ast.Rule) = .empty;
    for (raws) |raw| {
        try rules.appendSlice(arena, try parseRaw(arena, lang, raw, diag));
    }
    if (rules.items.len == 0) return null;

    return try compile(allocator, lang, .{ .rules = rules.items }, diag);
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
    lang: language.Name,
    file: ast.File,
    diag: *rule.Diagnostic,
) Error!rule.CompiledRule {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var ctx: Compiler = .{ .arena = arena, .lang = lang, .diag = diag };

    var patterns: std.ArrayList(rule.CompiledPattern) = .empty;
    for (file.rules) |*r| {
        ctx.rule_id = r.id;
        try validateLanguages(&ctx, r.*);
        if (r.kind == .project) continue;
        if (!includesLanguage(r.*, lang)) continue;
        try patterns.append(arena, try compileRule(&ctx, r.*));
    }

    const compiled = try patterns.toOwnedSlice(arena);
    return .{
        .patterns = compiled,
        .needs_measures = rule.needsMeasures(compiled),
        .arena = arena_ptr,
        .allocator = allocator,
    };
}

fn compileRule(ctx: *Compiler, r: ast.Rule) Error!rule.CompiledPattern {
    ctx.rule_id = r.id;
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
    if (!guaranteedCapture(pattern, emit_name)) {
        ctx.fail("emit capture must be bound in every alternation branch");
        return error.EmitCaptureMissingInBranch;
    }
    if (!std.mem.eql(u8, emit_name, rule.match_capture) and captureExists(pattern, rule.match_capture)) {
        ctx.fail("rule emits another capture but also binds @match");
        return error.EmitCaptureConflict;
    }

    var lowerer = lower.Lowerer.init(ctx.arena, language.grammar(ctx.lang));
    const lowered_pattern = lowerer.lowerPattern(pattern) catch |err| return mapLowerError(ctx, err);
    const lowered = lowerer.finish(lowered_pattern) catch |err| return mapLowerError(ctx, err);
    ctx.captures = lowered.capture_names;

    const meta = try compilePattern(ctx, r);
    return .{
        .pattern = lowered.pattern,
        .capture_count = lowered.capture_names.len,
        .match_capture_id = lowered.idForName(emit_name),
        .meta = meta,
    };
}

fn mapLowerError(ctx: *Compiler, err: lower.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownNodeKind, error.UnknownField => {
            ctx.fail("node kind or field is invalid for the grammar");
            return error.QueryCompileFailed;
        },
        error.AnonymousWithChildren => {
            ctx.fail("anonymous tokens cannot have child patterns");
            return error.UnsupportedMatch;
        },
        error.TooManyCaptures => {
            ctx.fail("too many captures in a single match");
            return error.QueryCompileFailed;
        },
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

fn captureExists(pattern: ast.NodePattern, name: []const u8) bool {
    if (pattern.capture) |capture| {
        if (std.mem.eql(u8, capture.name, name)) return true;
    }
    if (pattern.node_kind == .alternation) {
        for (pattern.node_kind.alternation) |branch| {
            if (captureExists(branch, name)) return true;
        }
    }
    for (pattern.fields) |field| {
        if (captureExists(field.pattern, name)) return true;
    }
    return false;
}

fn guaranteedCapture(pattern: ast.NodePattern, name: []const u8) bool {
    if (pattern.capture) |capture| {
        if (std.mem.eql(u8, capture.name, name)) return true;
    }
    if (pattern.node_kind == .alternation) {
        var in_every_branch = true;
        for (pattern.node_kind.alternation) |branch| {
            if (!guaranteedCapture(branch, name)) in_every_branch = false;
        }
        if (in_every_branch) return true;
    }
    for (pattern.fields) |field| {
        if (guaranteedCapture(field.pattern, name)) return true;
    }
    return false;
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
        .group => |group| try out.append(ctx.arena, try groupPredicate(ctx, group)),
    }
}

fn groupPredicate(ctx: *Compiler, group: ast.Group) Error!rule.Predicate {
    var members: std.ArrayList(rule.Predicate) = .empty;
    if (group.op == .all) {
        for (group.predicates) |member| {
            try translatePredicate(ctx, member, &members);
        }
        return .{ .all_group = try members.toOwnedSlice(ctx.arena) };
    }
    for (group.predicates) |member| {
        var conjuncts: std.ArrayList(rule.Predicate) = .empty;
        try translatePredicate(ctx, member, &conjuncts);
        if (conjuncts.items.len == 1) {
            try members.append(ctx.arena, conjuncts.items[0]);
        } else {
            try members.append(ctx.arena, .{ .all_group = try conjuncts.toOwnedSlice(ctx.arena) });
        }
    }
    return .{ .any_group = try members.toOwnedSlice(ctx.arena) };
}

fn compositionPredicate(ctx: *Compiler, composition: ast.Composition) Error!rule.Predicate {
    const op: rule.PredicateOp = switch (composition.op) {
        .inside => if (composition.negated) .not_inside else .inside,
        .has => if (composition.negated) .not_has else .has,
        .parent => if (composition.negated) .not_parent else .parent,
    };
    const pred: rule.NestedPredicate = .{
        .args = try subjectArgs(ctx, composition.matcher),
        .matcher = try compileNestedMatcher(ctx, composition.matcher),
    };
    return switch (op) {
        .inside => .{ .inside = pred },
        .not_inside => .{ .not_inside = pred },
        .has => .{ .has = pred },
        .not_has => .{ .not_has = pred },
        .parent => .{ .parent = pred },
        .not_parent => .{ .not_parent = pred },
        else => unreachable,
    };
}

fn countPredicate(ctx: *Compiler, count: ast.CountPredicate) Error!rule.Predicate {
    return .{ .count = .{
        .args = try subjectArgs(ctx, count.matcher),
        .matcher = try compileNestedMatcher(ctx, count.matcher),
        .compare = .{ .op = compareOp(count.op), .value = count.value },
    } };
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

    var pattern = matcher.pattern;
    if (pattern.capture == null) pattern.capture = .{ .name = nested_root_capture, .range = pattern.range };
    const root_name = pattern.capture.?.name;

    var lowerer = lower.Lowerer.init(ctx.arena, language.grammar(ctx.lang));
    const lowered_pattern = lowerer.lowerPattern(pattern) catch |err| return mapLowerError(ctx, err);
    const lowered = lowerer.finish(lowered_pattern) catch |err| return mapLowerError(ctx, err);

    const outer_captures = ctx.captures;
    ctx.captures = lowered.capture_names;
    defer ctx.captures = outer_captures;

    var predicates: std.ArrayList(rule.Predicate) = .empty;
    for (matcher.where) |expression| {
        try translateExpression(ctx, expression, &predicates);
    }

    const out = try ctx.arena.create(rule.NestedMatcher);
    out.* = .{
        .pattern = lowered.pattern,
        .capture_count = lowered.capture_names.len,
        .root_capture_id = lowered.idForName(root_name).?,
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
        try out.append(ctx.arena, .{ .where = pointer });
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
        .membership => |m| membershipPredicate(ctx, m, negated),
        else => null,
    };
}

fn membershipPredicate(ctx: *Compiler, m: ast.Membership, negated: bool) Error!?rule.Predicate {
    const subject = (try textOperand(ctx, m.subject.*)) orelse {
        ctx.fail("in expects text(@capture) on the left");
        return error.UnsupportedPredicate;
    };
    if (subject != .capture) {
        ctx.fail("in expects text(@capture) on the left");
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(rule.PredicateOperand, m.values.len + 1);
    args[0] = subject;
    for (m.values, args[1..]) |value, *slot| slot.* = .{ .string = try ctx.arena.dupe(u8, value.value) };
    const effective = m.negated != negated;
    return if (effective) .{ .not_any_of = args } else .{ .any_of = args };
}

fn anyOfPredicate(ctx: *Compiler, expression: ast.Expression, negated: bool) Error!?rule.Predicate {
    var capture: ?query.CaptureId = null;
    var strings: std.ArrayList([]const u8) = .empty;
    if (!try collectDisjunction(ctx, expression, &capture, &strings)) return null;

    const args = try ctx.arena.alloc(rule.PredicateOperand, strings.items.len + 1);
    args[0] = .{ .capture = capture.? };
    for (strings.items, args[1..]) |s, *slot| slot.* = .{ .string = s };
    return if (negated) .{ .not_any_of = args } else .{ .any_of = args };
}

fn collectDisjunction(
    ctx: *Compiler,
    expression: ast.Expression,
    capture: *?query.CaptureId,
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
    if (std.mem.eql(u8, call.name, "anyOf")) return anyOfHelperPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "noneOf")) return anyOfHelperPredicate(ctx, call, !negated);
    if (stringHelperOp(call.name, negated)) |op| return stringHelperPredicate(ctx, call, op);
    return null;
}

fn anyOfHelperPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    const fail_detail = "anyOf and noneOf expect (text(@capture), \"a\", \"b\", ...)";
    if (call.args.len < 2) {
        ctx.fail(fail_detail);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.fail(fail_detail);
        return error.UnsupportedPredicate;
    };
    if (subject != .capture) {
        ctx.fail(fail_detail);
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(rule.PredicateOperand, call.args.len);
    args[0] = subject;
    for (call.args[1..], args[1..]) |arg, *slot| {
        if (arg != .string) {
            ctx.fail(fail_detail);
            return error.UnsupportedPredicate;
        }
        slot.* = .{ .string = try ctx.arena.dupe(u8, arg.string.value) };
    }
    return if (negated) .{ .not_any_of = args } else .{ .any_of = args };
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
    return if (negated) .{ .not_glob = args } else .{ .glob = args };
}

fn capturedPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?rule.Predicate {
    if (call.args.len != 1 or call.args[0] != .capture) {
        ctx.fail("capture expects one capture argument");
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(rule.PredicateOperand, 1);
    args[0] = .{ .capture = try resolveCapture(ctx, call.args[0].capture.name) };
    return if (negated) .{ .not_captured = args } else .{ .captured = args };
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
    return switch (op) {
        .starts_with => .{ .starts_with = args },
        .not_starts_with => .{ .not_starts_with = args },
        .ends_with => .{ .ends_with = args },
        .not_ends_with => .{ .not_ends_with = args },
        .contains => .{ .contains = args },
        .not_contains => .{ .not_contains = args },
        else => unreachable,
    };
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
    const pred: rule.RegexPredicate = .{ .args = args, .regex = regex };
    return if (negated) .{ .not_match = pred } else .{ .match = pred };
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
        return if (wants_eq) .{ .eq = args } else .{ .not_eq = args };
    }
    if (left != null and right != null) {
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
    return expr.Measure.fromString(name);
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

fn resolveCapture(ctx: *Compiler, name: []const u8) Error!query.CaptureId {
    for (ctx.captures, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, name)) return @intCast(i);
    }

    ctx.fail("unknown capture");
    return error.UnknownCapture;
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

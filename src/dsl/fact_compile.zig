const std = @import("std");
const mvzr = @import("mvzr");

const ast = @import("ast.zig");
const dsl_parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");

const fact_rule = @import("../lint/fact_rule.zig");
const rule = @import("../lint/rule.zig");

pub const Error = error{
    OutOfMemory,
    UnsupportedClause,
    UnsupportedMatch,
    UnsupportedPredicate,
    UnsupportedPlaceholder,
    UnknownCapture,
    InvalidRegex,
    InvalidStringComparison,
};

pub const RawError = Error || dsl_parser.Error || error{
    RuleIdMismatch,
    LocalRuleInProjectDir,
};

pub fn compileRaws(
    arena: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) RawError![]fact_rule.CompiledFactRule {
    var rules: std.ArrayList(ast.Rule) = .empty;
    for (raws) |raw| {
        try rules.appendSlice(arena, try parseRaw(arena, raw, diag));
    }

    return compile(arena, .{ .rules = rules.items }, diag);
}

fn parseRaw(
    arena: std.mem.Allocator,
    raw: rule.RawRule,
    diag: *rule.Diagnostic,
) RawError![]const ast.Rule {
    var parse_diag: dsl_parser.Diagnostic = .{};
    var p = try dsl_parser.Parser.init(arena, raw.source, &parse_diag);
    const file = p.parseFile() catch |err| {
        diag.* = .{
            .rule_id = raw.id,
            .detail = "invalid rule syntax",
            .line = parse_diag.line,
            .column = parse_diag.column,
        };
        return err;
    };
    for (file.rules) |r| {
        if (r.kind != .project) {
            diag.* = .{ .rule_id = raw.id, .detail = "rules in rules/project must declare kind project" };
            return error.LocalRuleInProjectDir;
        }
        if (!std.mem.eql(u8, r.id, raw.id)) {
            diag.* = .{ .rule_id = raw.id, .detail = "rule id does not match the file name" };
            return error.RuleIdMismatch;
        }
    }

    return file.rules;
}

const unknown_fact_detail = "unknown fact (expected class, method, typedDecl, call, or import)";
const required_match_detail = "project rules require match <fact> @capture";

const Compiler = struct {
    arena: std.mem.Allocator,
    diag: *rule.Diagnostic,
    rule_id: []const u8 = "",
    fact: fact_rule.FactKind = .call,
    capture: []const u8 = "",

    fn fail(self: *Compiler, detail: []const u8) void {
        self.diag.* = .{ .rule_id = self.rule_id, .detail = detail };
    }

    fn failAt(self: *Compiler, detail: []const u8, range: tokenizer.Range) void {
        self.diag.* = .{
            .rule_id = self.rule_id,
            .detail = detail,
            .line = range.start.line,
            .column = range.start.column,
        };
    }
};

pub fn compile(
    arena: std.mem.Allocator,
    file: ast.File,
    diag: *rule.Diagnostic,
) Error![]fact_rule.CompiledFactRule {
    var ctx: Compiler = .{ .arena = arena, .diag = diag };
    var out: std.ArrayList(fact_rule.CompiledFactRule) = .empty;

    for (file.rules) |r| {
        if (r.kind != .project) continue;
        ctx.rule_id = r.id;
        try out.append(arena, try compileRule(&ctx, r));
    }

    return out.toOwnedSlice(arena);
}

fn compileRule(ctx: *Compiler, r: ast.Rule) Error!fact_rule.CompiledFactRule {
    if (r.languages.len != 0) {
        ctx.fail("project rules do not take a lang clause - filter with field(@x, lang)");
        return error.UnsupportedClause;
    }

    const subject = try factSubject(ctx, r);
    ctx.fact = subject.fact;
    ctx.capture = subject.capture;

    var predicates: std.ArrayList(fact_rule.Predicate) = .empty;
    for (r.where) |predicate| try translatePredicate(ctx, predicate, &predicates);

    if (!std.mem.eql(u8, r.emit.capture.name, ctx.capture)) {
        ctx.failAt("emit must use the fact capture", r.emit.capture.range);
        return error.UnknownCapture;
    }

    return .{
        .id = try ctx.arena.dupe(u8, r.id),
        .fact = ctx.fact,
        .predicates = try predicates.toOwnedSlice(ctx.arena),
        .message = try compileMessage(ctx, r.emit.message),
        .severity = switch (r.severity) {
            .@"error" => .@"error",
            .warn => .warn,
        },
        .exclude_paths = try dupeAll(ctx.arena, r.exclude_paths),
    };
}

const Subject = struct {
    fact: fact_rule.FactKind,
    capture: []const u8,
};

fn factSubject(ctx: *Compiler, r: ast.Rule) Error!Subject {
    const match_clause = r.match orelse {
        ctx.fail(required_match_detail);
        return error.UnsupportedMatch;
    };
    const pattern = switch (match_clause) {
        .node => |node| node,
        .kind => |kind| {
            ctx.failAt(required_match_detail, kind.range);
            return error.UnsupportedMatch;
        },
    };
    const symbol = switch (pattern.node_kind) {
        .symbol => |s| s,
        .anonymous, .alternation => {
            ctx.failAt(unknown_fact_detail, pattern.range);
            return error.UnsupportedMatch;
        },
    };
    const fact = fact_rule.FactKind.fromString(symbol) orelse {
        ctx.failAt(unknown_fact_detail, pattern.range);
        return error.UnsupportedMatch;
    };
    if (pattern.fields.len != 0) {
        ctx.failAt("fact matchers take no fields", pattern.range);
        return error.UnsupportedMatch;
    }
    const capture = pattern.capture orelse {
        ctx.failAt(required_match_detail, pattern.range);
        return error.UnsupportedMatch;
    };

    return .{ .fact = fact, .capture = capture.name };
}

fn translatePredicate(
    ctx: *Compiler,
    predicate: ast.Predicate,
    out: *std.ArrayList(fact_rule.Predicate),
) Error!void {
    switch (predicate) {
        .expression => |expression| try translateExpression(ctx, expression, out),
        .composition, .count => {
            ctx.fail("composition predicates are not supported in project rules");
            return error.UnsupportedPredicate;
        },
    }
}

fn translateExpression(
    ctx: *Compiler,
    expression: ast.Expression,
    out: *std.ArrayList(fact_rule.Predicate),
) Error!void {
    if (expression == .logical and expression.logical.op == .@"and") {
        try translateExpression(ctx, expression.logical.left.*, out);
        try translateExpression(ctx, expression.logical.right.*, out);
        return;
    }
    if (try predicateFrom(ctx, expression, false)) |pred| {
        try out.append(ctx.arena, pred);
        return;
    }

    ctx.fail("unsupported where expression in a project rule");
    return error.UnsupportedPredicate;
}

fn predicateFrom(ctx: *Compiler, expression: ast.Expression, negated: bool) Error!?fact_rule.Predicate {
    return switch (expression) {
        .negate => |negate| predicateFrom(ctx, negate.expression.*, !negated),
        .call => |call| callPredicate(ctx, call, negated),
        .compare => |c| comparePredicate(ctx, c, negated),
        .logical => |logical| if (logical.op == .@"or") anyOfPredicate(ctx, expression, negated) else null,
        .membership => |m| membershipPredicate(ctx, m, negated),
        else => null,
    };
}

fn membershipPredicate(ctx: *Compiler, m: ast.Membership, negated: bool) Error!?fact_rule.Predicate {
    const subject = (try textOperand(ctx, m.subject.*)) orelse {
        ctx.failAt("in expects field(@fact, name) on the left", m.range);
        return error.UnsupportedPredicate;
    };
    if (subject == .literal) {
        ctx.failAt("in expects field(@fact, name) on the left", m.range);
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(fact_rule.Operand, m.values.len + 1);
    args[0] = subject;
    for (m.values, args[1..]) |value, *slot| slot.* = .{ .literal = try ctx.arena.dupe(u8, value.value) };
    const effective = m.negated != negated;
    return .{ .op = if (effective) .not_any_of else .any_of, .args = args };
}

fn callPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?fact_rule.Predicate {
    if (std.mem.eql(u8, call.name, "matches")) return matchesPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "glob")) return globPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "anyOf")) return anyOfHelperPredicate(ctx, call, negated);
    if (std.mem.eql(u8, call.name, "noneOf")) return anyOfHelperPredicate(ctx, call, !negated);
    if (stringHelperOp(call.name, negated)) |op| return stringHelperPredicate(ctx, call, op);

    return null;
}

fn anyOfHelperPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?fact_rule.Predicate {
    const fail_detail = "anyOf and noneOf expect (field(@fact, name), \"a\", \"b\", ...)";
    if (call.args.len < 2) {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    };
    if (subject == .literal) {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    }
    const args = try ctx.arena.alloc(fact_rule.Operand, call.args.len);
    args[0] = subject;
    for (call.args[1..], args[1..]) |arg, *slot| {
        if (arg != .string) {
            ctx.failAt(fail_detail, call.range);
            return error.UnsupportedPredicate;
        }
        slot.* = .{ .literal = try ctx.arena.dupe(u8, arg.string.value) };
    }
    return .{ .op = if (negated) .not_any_of else .any_of, .args = args };
}

fn matchesPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?fact_rule.Predicate {
    if (call.args.len != 2) {
        ctx.failAt("matches expects (value, regex)", call.range);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.failAt("matches expects a text value", call.range);
        return error.UnsupportedPredicate;
    };
    const pattern = switch (call.args[1]) {
        .string => |s| try ctx.arena.dupe(u8, s.value),
        else => {
            ctx.failAt("matches expects a string regex", call.range);
            return error.UnsupportedPredicate;
        },
    };
    const regex = mvzr.compile(pattern) orelse {
        ctx.failAt("invalid regex", call.range);
        return error.InvalidRegex;
    };
    const args = try ctx.arena.alloc(fact_rule.Operand, 1);
    args[0] = subject;

    return .{ .op = if (negated) .not_match else .match, .args = args, .regex = regex };
}

fn globPredicate(ctx: *Compiler, call: ast.Call, negated: bool) Error!?fact_rule.Predicate {
    const fail_detail = "glob expects (value, \"pattern\")";
    if (call.args.len != 2 or call.args[1] != .string) {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    };
    const args = try ctx.arena.alloc(fact_rule.Operand, 2);
    args[0] = subject;
    args[1] = .{ .literal = try ctx.arena.dupe(u8, call.args[1].string.value) };

    return .{ .op = if (negated) .not_glob else .glob, .args = args };
}

fn stringHelperOp(name: []const u8, negated: bool) ?fact_rule.Op {
    if (std.mem.eql(u8, name, "startsWith")) return if (negated) .not_starts_with else .starts_with;
    if (std.mem.eql(u8, name, "endsWith")) return if (negated) .not_ends_with else .ends_with;
    if (std.mem.eql(u8, name, "contains")) return if (negated) .not_contains else .contains;

    return null;
}

fn stringHelperPredicate(ctx: *Compiler, call: ast.Call, op: fact_rule.Op) Error!?fact_rule.Predicate {
    const fail_detail = "startsWith, endsWith, and contains expect (value, text)";
    if (call.args.len != 2) {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    }
    const subject = (try textOperand(ctx, call.args[0])) orelse {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    };
    const candidate = (try textOperand(ctx, call.args[1])) orelse {
        ctx.failAt(fail_detail, call.range);
        return error.UnsupportedPredicate;
    };
    const args = try ctx.arena.alloc(fact_rule.Operand, 2);
    args[0] = subject;
    args[1] = candidate;

    return .{ .op = op, .args = args };
}

fn comparePredicate(ctx: *Compiler, c: ast.Compare, negated: bool) Error!?fact_rule.Predicate {
    const left = try textOperand(ctx, c.left.*);
    const right = try textOperand(ctx, c.right.*);
    if (c.op == .eq or c.op == .ne) {
        const resolved_left = left orelse return null;
        const resolved_right = right orelse return null;
        const wants_eq = (c.op == .eq) != negated;
        const args = try ctx.arena.alloc(fact_rule.Operand, 2);
        args[0] = resolved_left;
        args[1] = resolved_right;
        return .{ .op = if (wants_eq) .eq else .not_eq, .args = args };
    }
    if (left != null or right != null) {
        ctx.failAt("strings compare with == and != only", c.range);
        return error.InvalidStringComparison;
    }

    return null;
}

fn anyOfPredicate(ctx: *Compiler, expression: ast.Expression, negated: bool) Error!?fact_rule.Predicate {
    var subject: ?fact_rule.Operand = null;
    var literals: std.ArrayList([]const u8) = .empty;
    if (!try collectDisjunction(ctx, expression, &subject, &literals)) return null;

    const args = try ctx.arena.alloc(fact_rule.Operand, literals.items.len + 1);
    args[0] = subject.?;
    for (literals.items, args[1..]) |s, *slot| slot.* = .{ .literal = s };

    return .{ .op = if (negated) .not_any_of else .any_of, .args = args };
}

fn collectDisjunction(
    ctx: *Compiler,
    expression: ast.Expression,
    subject: *?fact_rule.Operand,
    literals: *std.ArrayList([]const u8),
) Error!bool {
    switch (expression) {
        .logical => |logical| {
            if (logical.op != .@"or") return false;
            if (!try collectDisjunction(ctx, logical.left.*, subject, literals)) return false;
            return collectDisjunction(ctx, logical.right.*, subject, literals);
        },
        .compare => |c| {
            if (c.op != .eq) return false;
            const left = (try textOperand(ctx, c.left.*)) orelse return false;
            const right = (try textOperand(ctx, c.right.*)) orelse return false;
            const leaf_subject = if (left == .literal) right else left;
            const leaf_literal = if (left == .literal) left else right;
            if (leaf_subject == .literal or leaf_literal != .literal) return false;
            if (subject.*) |seen| {
                if (!operandEq(seen, leaf_subject)) return false;
            } else {
                subject.* = leaf_subject;
            }
            try literals.append(ctx.arena, leaf_literal.literal);
            return true;
        },
        else => return false,
    }
}

fn operandEq(a: fact_rule.Operand, b: fact_rule.Operand) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    return switch (a) {
        .field => |f| f == b.field,
        .literal => |s| std.mem.eql(u8, s, b.literal),
        .receiver_type, .resolved_import_source => true,
    };
}

fn textOperand(ctx: *Compiler, expression: ast.Expression) Error!?fact_rule.Operand {
    return switch (expression) {
        .string => |s| .{ .literal = try ctx.arena.dupe(u8, s.value) },
        .call => |call| try callOperand(ctx, call),
        else => null,
    };
}

fn callOperand(ctx: *Compiler, call: ast.Call) Error!?fact_rule.Operand {
    if (std.mem.eql(u8, call.name, "field")) return try fieldOperand(ctx, call);
    if (std.mem.eql(u8, call.name, "receiverType"))
        return try helperOperand(ctx, call, .call, .receiver_type, "receiverType expects the call fact");
    if (std.mem.eql(u8, call.name, "resolvedImportSource"))
        return try helperOperand(ctx, call, .import, .resolved_import_source, "resolvedImportSource expects the import fact");
    if (std.mem.eql(u8, call.name, "text")) {
        ctx.failAt("text is not available in project rules - use field(@fact, name)", call.range);
        return error.UnsupportedPredicate;
    }

    return null;
}

fn fieldOperand(ctx: *Compiler, call: ast.Call) Error!?fact_rule.Operand {
    if (call.args.len != 2 or call.args[0] != .capture or call.args[1] != .symbol) {
        ctx.failAt("field expects (@fact, name)", call.range);
        return error.UnsupportedPredicate;
    }
    try checkSubject(ctx, call.args[0].capture);
    const field = fact_rule.fieldFromString(call.args[1].symbol.name) orelse {
        ctx.failAt("unknown fact field", call.args[1].symbol.range);
        return error.UnsupportedPredicate;
    };
    if (!fact_rule.factHasField(ctx.fact, field)) {
        ctx.failAt("field is not defined for this fact", call.args[1].symbol.range);
        return error.UnsupportedPredicate;
    }

    return .{ .field = field };
}

fn helperOperand(
    ctx: *Compiler,
    call: ast.Call,
    expected_fact: fact_rule.FactKind,
    operand: fact_rule.Operand,
    wrong_fact_detail: []const u8,
) Error!?fact_rule.Operand {
    if (call.args.len != 1 or call.args[0] != .capture) {
        ctx.failAt("project helpers expect one capture argument", call.range);
        return error.UnsupportedPredicate;
    }
    try checkSubject(ctx, call.args[0].capture);
    if (ctx.fact != expected_fact) {
        ctx.failAt(wrong_fact_detail, call.range);
        return error.UnsupportedPredicate;
    }

    return operand;
}

fn checkSubject(ctx: *Compiler, capture: ast.Capture) Error!void {
    if (std.mem.eql(u8, capture.name, ctx.capture)) return;

    ctx.failAt("unknown capture", capture.range);
    return error.UnknownCapture;
}

fn compileMessage(ctx: *Compiler, message: []const u8) Error![]const fact_rule.MessageSegment {
    var segments: std.ArrayList(fact_rule.MessageSegment) = .empty;
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
            try segments.append(ctx.arena, .{ .operand = try placeholderOperand(ctx, message[i + 1 .. close]) });
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

    return segments.toOwnedSlice(ctx.arena);
}

fn placeholderOperand(ctx: *Compiler, inner: []const u8) Error!fact_rule.Operand {
    const open = std.mem.indexOfScalar(u8, inner, '(') orelse return failPlaceholder(ctx);
    if (inner.len == 0 or inner[inner.len - 1] != ')') return failPlaceholder(ctx);

    const name = inner[0..open];
    var args = std.mem.splitScalar(u8, inner[open + 1 .. inner.len - 1], ',');
    const first = std.mem.trim(u8, args.next() orelse return failPlaceholder(ctx), " ");
    if (first.len < 2 or first[0] != '@') return failPlaceholder(ctx);
    try checkSubjectName(ctx, first[1..]);

    if (std.mem.eql(u8, name, "field")) {
        const second = std.mem.trim(u8, args.next() orelse return failPlaceholder(ctx), " ");
        if (args.next() != null or second.len == 0) return failPlaceholder(ctx);
        const field = fact_rule.fieldFromString(second) orelse {
            ctx.fail("unknown fact field");
            return error.UnsupportedPlaceholder;
        };
        if (!fact_rule.factHasField(ctx.fact, field)) {
            ctx.fail("field is not defined for this fact");
            return error.UnsupportedPlaceholder;
        }
        return .{ .field = field };
    }

    if (args.next() != null) return failPlaceholder(ctx);
    if (std.mem.eql(u8, name, "receiverType")) {
        if (ctx.fact != .call) {
            ctx.fail("receiverType expects the call fact");
            return error.UnsupportedPlaceholder;
        }
        return .receiver_type;
    }
    if (std.mem.eql(u8, name, "resolvedImportSource")) {
        if (ctx.fact != .import) {
            ctx.fail("resolvedImportSource expects the import fact");
            return error.UnsupportedPlaceholder;
        }
        return .resolved_import_source;
    }

    return failPlaceholder(ctx);
}

fn checkSubjectName(ctx: *Compiler, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, ctx.capture)) return;

    ctx.fail("unknown capture");
    return error.UnknownCapture;
}

fn failPlaceholder(ctx: *Compiler) Error {
    ctx.fail("message placeholder must be {field(@fact, name)} or a project helper");
    return error.UnsupportedPlaceholder;
}

fn dupeAll(arena: std.mem.Allocator, items: []const []const u8) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try arena.dupe(u8, item);

    return out;
}

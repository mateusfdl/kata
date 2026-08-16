const std = @import("std");
const mvzr = @import("mvzr");

const ast = @import("ast.zig");
const bytes = @import("bytes.zig");
const lower = @import("lower.zig");
const scalar_compile = @import("scalar_compile.zig");
const tokenizer = @import("tokenizer.zig");
const diagnostic = @import("engine").diagnostic;
const dsl_parser = @import("parser.zig");
const expr = @import("engine").expr;
const family = @import("engine").family;
const language = @import("engine").language;
const OwnedArena = @import("shared").owned_arena.OwnedArena;
const query = @import("engine").query;
const rule = @import("engine").rule;
const ScratchMemory = @import("shared").scratch_memory.ScratchMemory;

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
    FixCaptureMissingInBranch,
    InvalidRegex,
    InvalidStringComparison,
    ReservedCapture,
};

const ScalarError = Error;

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
    adapter: *const family.Adapter,
    rule_id: []const u8 = "",
    captures: []const []const u8 = &.{},

    fn fail(self: *Compiler, detail: []const u8) void {
        self.diag.* = .{ .lang = self.lang, .rule_id = self.rule_id, .detail = detail };
    }
};

const ScalarAdapter = struct {
    pub const Context = Compiler;
    pub const Error = ScalarError;
    pub const Operand = rule.PredicateOperand;
    pub const Predicate = rule.Predicate;
    pub const any_of_detail = "anyOf and noneOf expect (text(@capture), \"a\", \"b\", ...)";
    pub const membership_detail = "in expects text(@capture) on the left";
    pub const compare_has_numeric_fallback = true;

    const ExtraCallHandler = *const fn (*Compiler, ast.Call, bool) ScalarError!?rule.Predicate;
    pub const extra_call_dispatch = std.StaticStringMap(ExtraCallHandler).initComptime(.{
        .{ bytes.call_capture, capturedScalarPredicate },
    });

    pub fn allocator(ctx: *Compiler) std.mem.Allocator {
        return ctx.arena;
    }

    pub fn textOperand(ctx: *Compiler, expression: ast.Expression) ScalarError!?rule.PredicateOperand {
        switch (expression) {
            .string => |string| return .{ .string = try ctx.arena.dupe(u8, string.value) },
            .call => |call| {
                if (!std.mem.eql(u8, call.name, bytes.call_text)) return null;
                if (call.args.len != 1 or call.args[0] != .capture) {
                    return failWith(ctx, "text expects one capture argument", call.range);
                }

                return .{ .capture = try resolveCapture(ctx, call.args[0].capture.name) };
            },
            else => return null,
        }
    }

    pub fn literalOperand(ctx: *Compiler, value: []const u8) ScalarError!rule.PredicateOperand {
        return .{ .string = try ctx.arena.dupe(u8, value) };
    }

    pub fn isAnyOfSubject(operand: rule.PredicateOperand) bool {
        return operand == .capture;
    }

    pub fn literalValue(operand: rule.PredicateOperand) ?[]const u8 {
        return switch (operand) {
            .capture => null,
            .string => |value| value,
        };
    }

    pub fn operandEql(left: rule.PredicateOperand, right: rule.PredicateOperand) bool {
        return switch (left) {
            .capture => |capture| right == .capture and capture == right.capture,
            .string => |value| right == .string and std.mem.eql(u8, value, right.string),
        };
    }

    pub fn emit(op: scalar_compile.Operation, args: []rule.PredicateOperand) rule.Predicate {
        return switch (op) {
            .eq => .{ .eq = args },
            .not_eq => .{ .not_eq = args },
            .any_of => .{ .any_of = args },
            .not_any_of => .{ .not_any_of = args },
            .starts_with => .{ .starts_with = args },
            .not_starts_with => .{ .not_starts_with = args },
            .ends_with => .{ .ends_with = args },
            .not_ends_with => .{ .not_ends_with = args },
            .contains => .{ .contains = args },
            .not_contains => .{ .not_contains = args },
            .glob => .{ .glob = args },
            .not_glob => .{ .not_glob = args },
        };
    }

    pub fn emitRegex(
        ctx: *Compiler,
        subject: rule.PredicateOperand,
        pattern: []const u8,
        regex: mvzr.Regex,
        negated: bool,
    ) ScalarError!rule.Predicate {
        const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
        args[0] = subject;
        args[1] = .{ .string = pattern };
        const predicate: rule.RegexPredicate = .{ .args = args, .regex = regex };
        return if (negated) .{ .not_match = predicate } else .{ .match = predicate };
    }

    pub fn report(ctx: *Compiler, detail: []const u8, _: tokenizer.Range) void {
        ctx.fail(detail);
    }

    pub fn failWith(ctx: *Compiler, detail: []const u8, range: tokenizer.Range) ScalarError {
        report(ctx, detail, range);
        return error.UnsupportedPredicate;
    }

    fn capturedScalarPredicate(ctx: *Compiler, call: ast.Call, negated: bool) ScalarError!?rule.Predicate {
        if (call.args.len != 1 or call.args[0] != .capture) {
            return failWith(ctx, "capture expects one capture argument", call.range);
        }

        const args = try ctx.arena.alloc(rule.PredicateOperand, 1);
        args[0] = .{ .capture = try resolveCapture(ctx, call.args[0].capture.name) };
        return if (negated) .{ .not_captured = args } else .{ .captured = args };
    }
};

const Scalar = scalar_compile.ScalarCompiler(ScalarAdapter);

pub fn compileRaws(
    allocator: std.mem.Allocator,
    lang: language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) RawError!?rule.CompiledRule {
    var scratch = ScratchMemory.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var rules: std.ArrayList(ast.Rule) = .empty;
    for (raws) |raw| {
        try rules.appendSlice(arena, try parseRaw(arena, lang, raw, diag));
    }

    if (rules.items.len == 0) {
        const parse_generation = scratch.generation();
        scratch.reset();
        std.debug.assert(scratch.generation() == parse_generation + 1);
        return null;
    }

    const compiled = try compile(allocator, lang, .{ .rules = rules.items }, diag);
    const parse_generation = scratch.generation();
    scratch.reset();
    std.debug.assert(scratch.generation() == parse_generation + 1);
    return compiled;
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
    const owned_arena = try OwnedArena.create(allocator);
    errdefer owned_arena.deinit();
    const arena = owned_arena.allocator();

    var ctx: Compiler = .{ .arena = arena, .lang = lang, .diag = diag, .adapter = family.of(lang.family()) };

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
        .arena = owned_arena,
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

    var lowerer = lower.Lowerer.init(ctx.arena, ctx.adapter);
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
        const all = for (pattern.node_kind.alternation) |branch| {
            if (!guaranteedCapture(branch, name)) break false;
        } else true;
        if (all) return true;
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
        .fix = try compileFix(ctx, r),
        .suggestions = try compileSuggestions(ctx, r),
        .rule_id = try ctx.arena.dupe(u8, r.id),
        .exclude_paths = try bytes.dupeAll(ctx.arena, r.exclude_paths),
        .severity = switch (r.severity) {
            .@"error" => .@"error",
            .warn => .warn,
        },
        .maturity = switch (r.maturity) {
            .experimental => .experimental,
            .stable => .stable,
            .deprecated => .deprecated,
        },
    };
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
        .fact_exists, .fact_count => {
            ctx.fail("project fact queries are not supported in local rules");

            return error.UnsupportedPredicate;
        },
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
        .follows => if (composition.negated) .not_follows else .follows,
        .precedes => if (composition.negated) .not_precedes else .precedes,
        .between => if (composition.negated) .not_between else .between,
    };

    const pred: rule.NestedPredicate = .{
        .args = try compositionArgs(ctx, composition),
        .matcher = try compileNestedMatcher(ctx, composition.matcher),
        .until_kinds = try untilKinds(ctx, composition.until),
    };

    return switch (op) {
        .inside => .{ .inside = pred },
        .not_inside => .{ .not_inside = pred },
        .has => .{ .has = pred },
        .not_has => .{ .not_has = pred },
        .parent => .{ .parent = pred },
        .not_parent => .{ .not_parent = pred },
        .follows => .{ .follows = pred },
        .not_follows => .{ .not_follows = pred },
        .precedes => .{ .precedes = pred },
        .not_precedes => .{ .not_precedes = pred },
        .between => .{ .between = pred },
        .not_between => .{ .not_between = pred },
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

fn untilKinds(ctx: *Compiler, names: []const []const u8) Error![]const u16 {
    if (names.len == 0) return &.{};

    var ids: std.ArrayList(u16) = .empty;
    var lowerer = lower.Lowerer.init(ctx.arena, ctx.adapter);

    for (names) |name| {
        const members = lowerer.resolveKindMembers(name) catch |err| return mapLowerError(ctx, err);

        try ids.appendSlice(ctx.arena, members);
    }

    return ids.toOwnedSlice(ctx.arena);
}

fn subjectArgs(ctx: *Compiler, matcher: ast.NestedMatcher) Error![]rule.PredicateOperand {
    const args = try ctx.arena.alloc(rule.PredicateOperand, 1);
    args[0] = .{ .capture = try resolveCapture(ctx, matcher.subject.name) };

    return args;
}

fn compositionArgs(ctx: *Compiler, composition: ast.Composition) Error![]rule.PredicateOperand {
    const second = composition.second orelse return subjectArgs(ctx, composition.matcher);

    const args = try ctx.arena.alloc(rule.PredicateOperand, 2);
    args[0] = .{ .capture = try resolveCapture(ctx, composition.matcher.subject.name) };
    args[1] = .{ .capture = try resolveCapture(ctx, second.name) };

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

    var lowerer = lower.Lowerer.init(ctx.arena, ctx.adapter);
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

    if (try Scalar.predicateFrom(ctx, expression, false)) |pred| {
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

const deferred_calls = std.StaticStringMap(void).initComptime(.{
    .{ bytes.call_text, {} },
    .{ bytes.call_capture, {} },
    .{ bytes.call_matches, {} },
    .{ bytes.call_starts_with, {} },
    .{ bytes.call_ends_with, {} },
    .{ bytes.call_contains, {} },
});

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
            const measure = expr.Measure.fromString(call.name) orelse {
                if (deferred_calls.has(call.name)) return null;

                ctx.fail("unknown measure");

                return error.UnknownMeasure;
            };
            if (call.args.len != 1 or call.args[0] != .capture) {
                return ScalarAdapter.failWith(ctx, "measures expect one capture argument", call.range);
            }

            return .{ .measure = .{
                .measure = measure,
                .capture_id = try resolveCapture(ctx, call.args[0].capture.name),
            } };
        },
        else => return null,
    }
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
    const raw = bytes.scanMessage(ctx.arena, message) catch return failPlaceholder(ctx);
    const tokens = raw orelse return .{ .plain = try ctx.arena.dupe(u8, message) };

    if (tokens.len == 1 and tokens[0] == .literal) return .{ .plain = tokens[0].literal };

    const segments = try ctx.arena.alloc(rule.MessageSegment, tokens.len);
    for (tokens, segments) |tok, *seg| {
        seg.* = switch (tok) {
            .literal => |s| .{ .literal = s },
            .placeholder => |inner| .{ .placeholder = try parsePlaceholder(ctx, inner) },
        };
    }

    return .{ .segments = segments };
}

fn compileFix(ctx: *Compiler, r: ast.Rule) Error!?rule.Fix {
    const fix = r.emit.fix orelse return null;

    return .{
        .safety = switch (fix.safety) {
            .safe => .safe,
            .unsafe => .unsafe,
        },
        .target_id = try fixTargetId(ctx, r, fix.target),
        .template = try compileFixTemplate(ctx, r, fix.template),
    };
}

fn compileSuggestions(ctx: *Compiler, r: ast.Rule) Error![]const rule.Suggestion {
    if (r.emit.suggestions.len == 0) return &.{};

    const suggestions = try ctx.arena.alloc(rule.Suggestion, r.emit.suggestions.len);
    for (r.emit.suggestions, suggestions) |s, *out| {
        out.* = .{
            .label = try ctx.arena.dupe(u8, s.label),
            .target_id = try fixTargetId(ctx, r, s.target),
            .template = try compileFixTemplate(ctx, r, s.template),
        };
    }

    return suggestions;
}

fn fixTargetId(ctx: *Compiler, r: ast.Rule, target: ?ast.Capture) Error!query.CaptureId {
    const name = if (target) |t| t.name else r.emit.capture.name;
    const pattern = r.match.?.node;
    if (!captureExists(pattern, name)) {
        ctx.fail("fix capture not found in match");

        return error.UnknownCapture;
    }

    if (!guaranteedCapture(pattern, name)) {
        ctx.fail("fix capture must be bound in every alternation branch");

        return error.FixCaptureMissingInBranch;
    }

    return resolveCapture(ctx, name);
}

fn compileFixTemplate(ctx: *Compiler, r: ast.Rule, template: []const u8) Error!rule.Message {
    const message = try compileMessage(ctx, template);
    if (message != .segments) return message;

    const pattern = r.match.?.node;
    for (message.segments) |segment| {
        if (segment != .placeholder) continue;
        const name = ctx.captures[segment.placeholder.capture_id];
        if (guaranteedCapture(pattern, name)) continue;
        ctx.fail("fix capture must be bound in every alternation branch");

        return error.FixCaptureMissingInBranch;
    }

    return message;
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

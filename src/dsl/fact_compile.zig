const std = @import("std");
const mvzr = @import("mvzr");

const ast = @import("ast.zig");
const bytes = @import("bytes.zig");
const dsl_parser = @import("parser.zig");
const scalar_compile = @import("scalar_compile.zig");
const tokenizer = @import("tokenizer.zig");

const engine = @import("engine");
const fact_rule = engine.fact_rule;
const fact_schema = engine.fact_schema;
const rule = engine.rule;

const unknown_fact_detail = "unknown fact (expected " ++ expectedFactNames() ++ ")";
const required_match_detail = "project rules require match <fact> @capture";

fn expectedFactNames() []const u8 {
    comptime {
        var names: []const u8 = "";
        for (fact_schema.descriptors, 0..) |descriptor_value, i| {
            if (i != 0) names = names ++ ", ";
            if (i == fact_schema.descriptors.len - 1) names = names ++ "or ";
            names = names ++ descriptor_value.dsl_name;
        }

        return names;
    }
}

pub const Error = error{
    OutOfMemory,
    UnsupportedClause,
    UnsupportedMatch,
    UnsupportedPredicate,
    UnsupportedPlaceholder,
    UnknownCapture,
    DuplicateCapture,
    InvalidRegex,
    InvalidStringComparison,
    TooManyCaptures,
};

const ScalarError = Error;

pub const RawError = Error || dsl_parser.Error || error{
    RuleIdMismatch,
    LocalRuleInProjectDir,
};

const Compiler = struct {
    arena: std.mem.Allocator,
    diag: *rule.Diagnostic,
    rule_id: []const u8 = "",
    fact: fact_rule.FactKind = .call,
    capture: []const u8 = "",
    scopes: CaptureScopes = .{},

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

const ScalarAdapter = struct {
    pub const Context = Compiler;
    pub const Error = ScalarError;
    pub const Operand = fact_rule.Operand;
    pub const Predicate = fact_rule.ScalarPredicate;
    pub const any_of_detail = "anyOf and noneOf expect (field(@fact, name), \"a\", \"b\", ...)";
    pub const membership_detail = "in expects field(@fact, name) on the left";
    pub const compare_has_numeric_fallback = false;

    const ExtraCallHandler = *const fn (*Compiler, ast.Call, bool) ScalarError!?fact_rule.ScalarPredicate;
    pub const extra_call_dispatch = std.StaticStringMap(ExtraCallHandler).initComptime(.{});

    pub fn allocator(ctx: *Compiler) std.mem.Allocator {
        return ctx.arena;
    }

    pub fn textOperand(ctx: *Compiler, expression: ast.Expression) ScalarError!?fact_rule.Operand {
        return switch (expression) {
            .string => |string| .{ .literal = try ctx.arena.dupe(u8, string.value) },
            .call => |call| try callOperand(ctx, call),
            else => null,
        };
    }

    pub fn literalOperand(ctx: *Compiler, value: []const u8) ScalarError!fact_rule.Operand {
        return .{ .literal = try ctx.arena.dupe(u8, value) };
    }

    pub fn isAnyOfSubject(operand: fact_rule.Operand) bool {
        return operand != .literal;
    }

    pub fn literalValue(operand: fact_rule.Operand) ?[]const u8 {
        return switch (operand) {
            .field, .helper => null,
            .literal => |value| value,
        };
    }

    pub fn operandEql(left: fact_rule.Operand, right: fact_rule.Operand) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .field => |field| field.capture == right.field.capture and field.field == right.field.field,
            .literal => |value| std.mem.eql(u8, value, right.literal),
            .helper => |helper| helper.id == right.helper.id and helper.capture == right.helper.capture,
        };
    }

    pub fn emit(op: scalar_compile.Operation, args: []fact_rule.Operand) fact_rule.ScalarPredicate {
        return .{
            .op = switch (op) {
                .eq => .eq,
                .not_eq => .not_eq,
                .any_of => .any_of,
                .not_any_of => .not_any_of,
                .starts_with => .starts_with,
                .not_starts_with => .not_starts_with,
                .ends_with => .ends_with,
                .not_ends_with => .not_ends_with,
                .contains => .contains,
                .not_contains => .not_contains,
                .glob => .glob,
                .not_glob => .not_glob,
            },
            .args = args,
        };
    }

    pub fn emitRegex(
        ctx: *Compiler,
        subject: fact_rule.Operand,
        _: []const u8,
        regex: mvzr.Regex,
        negated: bool,
    ) ScalarError!fact_rule.ScalarPredicate {
        const args = try ctx.arena.alloc(fact_rule.Operand, 1);
        args[0] = subject;
        return .{ .op = if (negated) .not_match else .match, .args = args, .regex = regex };
    }

    pub fn report(ctx: *Compiler, detail: []const u8, range: tokenizer.Range) void {
        ctx.failAt(detail, range);
    }

    pub fn failWith(ctx: *Compiler, detail: []const u8, range: tokenizer.Range) ScalarError {
        report(ctx, detail, range);
        return error.UnsupportedPredicate;
    }
};

const Scalar = scalar_compile.ScalarCompiler(ScalarAdapter);

const Binding = struct {
    name: []const u8,
    fact: fact_rule.FactKind,
    capture: fact_rule.CaptureId,
};

const CaptureScopes = struct {
    bindings: std.ArrayList(Binding) = .empty,
    next_capture: fact_rule.CaptureId = 0,

    fn reset(self: *CaptureScopes, arena: std.mem.Allocator, name: []const u8, fact: fact_rule.FactKind) Error!void {
        self.bindings.clearRetainingCapacity();
        self.next_capture = 1;
        try self.bindings.append(arena, .{ .name = name, .fact = fact, .capture = 0 });
    }

    fn declare(
        self: *CaptureScopes,
        ctx: *Compiler,
        name: []const u8,
        fact: fact_rule.FactKind,
        range: tokenizer.Range,
    ) Error!fact_rule.CaptureId {
        if (self.resolve(name) != null) {
            ctx.failAt("duplicate capture", range);

            return error.DuplicateCapture;
        }

        const capture = self.next_capture;
        if (capture >= 64) {
            ctx.failAt("too many captures", range);

            return error.TooManyCaptures;
        }
        self.next_capture += 1;
        try self.bindings.append(ctx.arena, .{ .name = name, .fact = fact, .capture = capture });

        return capture;
    }

    fn resolve(self: *const CaptureScopes, name: []const u8) ?Binding {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.bindings.items[i];
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }

        return null;
    }

    fn push(self: *const CaptureScopes) usize {
        return self.bindings.items.len;
    }

    fn pop(self: *CaptureScopes, mark: usize) void {
        self.bindings.shrinkRetainingCapacity(mark);
    }

    fn count(self: *const CaptureScopes) fact_rule.CaptureId {
        return self.next_capture;
    }
};

const Subject = struct {
    fact: fact_rule.FactKind,
    capture: []const u8,
};

pub fn compileRaws(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) RawError![]fact_rule.CompiledFactRule {
    var rules: std.ArrayList(ast.Rule) = .empty;
    for (raws) |raw| {
        try rules.appendSlice(scratch_allocator, try parseRaw(scratch_allocator, raw, diag));
    }

    return compile(output_allocator, .{ .rules = rules.items }, diag);
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

    if (r.emit.fix != null or r.emit.suggestions.len != 0) {
        ctx.fail("fix and suggest are not supported in project rules");

        return error.UnsupportedClause;
    }

    const subject = try factSubject(ctx, r);

    ctx.fact = subject.fact;
    ctx.capture = subject.capture;
    try ctx.scopes.reset(ctx.arena, subject.capture, subject.fact);

    var predicates: std.ArrayList(fact_rule.Predicate) = .empty;
    for (r.where) |predicate| try translatePredicate(ctx, predicate, &predicates);

    if (!std.mem.eql(u8, r.emit.capture.name, ctx.capture)) {
        ctx.failAt("emit must use the fact capture", r.emit.capture.range);

        return error.UnknownCapture;
    }

    return .{
        .id = try ctx.arena.dupe(u8, r.id),
        .fact = ctx.fact,
        .capture_count = ctx.scopes.count(),
        .predicates = try predicates.toOwnedSlice(ctx.arena),
        .message = try compileMessage(ctx, r.emit.message),
        .severity = switch (r.severity) {
            .@"error" => .@"error",
            .warn => .warn,
        },
        .maturity = switch (r.maturity) {
            .experimental => .experimental,
            .stable => .stable,
            .deprecated => .deprecated,
        },
        .exclude_paths = try bytes.dupeAll(ctx.arena, r.exclude_paths),
    };
}

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
    if (pattern.fields.len != 0 or pattern.absent_fields.len != 0) {
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
            ctx.fail("tree composition predicates are not supported in project rules");

            return error.UnsupportedPredicate;
        },
        .group => |group| try out.append(ctx.arena, try groupPredicate(ctx, group)),
        .fact_exists => |exists| try out.append(ctx.arena, try existsPredicate(ctx, exists)),
        .fact_count => |count| try out.append(ctx.arena, try factCountPredicate(ctx, count)),
    }
}

fn groupPredicate(ctx: *Compiler, group: ast.Group) Error!fact_rule.Predicate {
    var members: std.ArrayList(fact_rule.Predicate) = .empty;
    if (group.op == .all) {
        for (group.predicates) |member| try translatePredicate(ctx, member, &members);

        const requires = membersRequires(members.items);

        return .{ .all_group = .{ .requires = requires, .members = try members.toOwnedSlice(ctx.arena) } };
    }

    for (group.predicates) |member| {
        var conjuncts: std.ArrayList(fact_rule.Predicate) = .empty;
        try translatePredicate(ctx, member, &conjuncts);
        if (conjuncts.items.len == 1) {
            try members.append(ctx.arena, conjuncts.items[0]);
        } else {
            const requires = membersRequires(conjuncts.items);
            try members.append(ctx.arena, .{ .all_group = .{ .requires = requires, .members = try conjuncts.toOwnedSlice(ctx.arena) } });
        }
    }

    const requires = membersRequires(members.items);

    return .{ .any_group = .{ .requires = requires, .members = try members.toOwnedSlice(ctx.arena) } };
}

fn existsPredicate(ctx: *Compiler, exists: ast.FactExistsPredicate) Error!fact_rule.Predicate {
    const query = try compileFactQuery(ctx, exists.query);

    return if (exists.negated) .{ .not_exists = query } else .{ .exists = query };
}

fn factCountPredicate(ctx: *Compiler, count: ast.FactCountPredicate) Error!fact_rule.Predicate {
    return .{ .count = .{
        .query = try compileFactQuery(ctx, count.query),
        .op = countCompare(count.op),
        .value = count.value,
    } };
}

fn compileFactQuery(ctx: *Compiler, query: ast.FactQuery) Error!fact_rule.FactQuery {
    const fact = fact_rule.FactKind.fromString(query.fact) orelse {
        ctx.failAt(unknown_fact_detail, query.range);

        return error.UnsupportedMatch;
    };
    const scope = ctx.scopes.push();
    defer ctx.scopes.pop(scope);
    const capture = try ctx.scopes.declare(ctx, query.capture.name, fact, query.capture.range);

    var predicates: std.ArrayList(fact_rule.Predicate) = .empty;
    for (query.where) |predicate| try translatePredicate(ctx, predicate, &predicates);

    const requires = membersRequires(predicates.items) & ~captureBit(capture);

    return .{
        .fact = fact,
        .capture = capture,
        .predicates = try predicates.toOwnedSlice(ctx.arena),
        .requires = requires,
    };
}

fn captureBit(capture: fact_rule.CaptureId) fact_rule.CaptureSet {
    return @as(fact_rule.CaptureSet, 1) << @intCast(capture);
}

fn membersRequires(predicates: []const fact_rule.Predicate) fact_rule.CaptureSet {
    var requires: fact_rule.CaptureSet = 0;
    for (predicates) |predicate| requires |= predicateRequires(predicate);

    return requires;
}

fn predicateRequires(predicate: fact_rule.Predicate) fact_rule.CaptureSet {
    return switch (predicate) {
        .scalar => |scalar| scalar.requires,
        .all_group, .any_group => |group| group.requires,
        .exists, .not_exists => |query| query.requires,
        .count => |count| count.query.requires,
    };
}

fn operandsRequires(args: []const fact_rule.Operand) fact_rule.CaptureSet {
    var requires: fact_rule.CaptureSet = 0;
    for (args) |operand| {
        requires |= switch (operand) {
            .literal => 0,
            .field => |field| captureBit(field.capture),
            .helper => |helper| captureBit(helper.capture),
        };
    }

    return requires;
}

fn countCompare(op: ast.CompareOp) fact_rule.CountCompare {
    return switch (op) {
        .gt => .gt,
        .ge => .ge,
        .lt => .lt,
        .le => .le,
        .eq => .eq,
        .ne => .ne,
    };
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

    if (try Scalar.predicateFrom(ctx, expression, false)) |pred| {
        var scalar = pred;
        scalar.requires = operandsRequires(pred.args);
        try out.append(ctx.arena, .{ .scalar = scalar });

        return;
    }

    ctx.fail("unsupported where expression in a project rule");

    return error.UnsupportedPredicate;
}

fn callOperand(ctx: *Compiler, call: ast.Call) Error!?fact_rule.Operand {
    if (std.mem.eql(u8, call.name, bytes.call_field)) return try fieldOperand(ctx, call);

    inline for (std.meta.fields(fact_schema.HelperId)) |helper_field| {
        const id: fact_schema.HelperId = @enumFromInt(helper_field.value);
        const descriptor_value = comptime fact_schema.descriptor(id);
        if (std.mem.eql(u8, call.name, descriptor_value.name)) {
            const wrong_fact_detail = comptime std.fmt.comptimePrint("{s} expects the {s} fact", .{
                descriptor_value.name,
                @tagName(descriptor_value.fact),
            });

            return try helperOperand(ctx, call, id, wrong_fact_detail);
        }
    }

    if (std.mem.eql(u8, call.name, bytes.call_text)) {
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

    const binding = ctx.scopes.resolve(call.args[0].capture.name) orelse {
        ctx.failAt("unknown capture", call.args[0].capture.range);

        return error.UnknownCapture;
    };

    const field = fact_rule.fieldFromString(call.args[1].symbol.name) orelse {
        ctx.failAt("unknown fact field", call.args[1].symbol.range);

        return error.UnsupportedPredicate;
    };

    if (!fact_rule.factHasField(binding.fact, field)) {
        ctx.failAt("field is not defined for this fact", call.args[1].symbol.range);

        return error.UnsupportedPredicate;
    }

    return .{ .field = .{ .capture = binding.capture, .field = field } };
}

fn helperOperand(
    ctx: *Compiler,
    call: ast.Call,
    comptime id: fact_schema.HelperId,
    wrong_fact_detail: []const u8,
) Error!?fact_rule.Operand {
    if (call.args.len != 1 or call.args[0] != .capture) {
        ctx.failAt("project helpers expect one capture argument", call.range);

        return error.UnsupportedPredicate;
    }

    const binding = ctx.scopes.resolve(call.args[0].capture.name) orelse {
        ctx.failAt("unknown capture", call.args[0].capture.range);

        return error.UnknownCapture;
    };
    const descriptor_value = comptime fact_schema.descriptor(id);

    if (binding.fact != descriptor_value.fact) {
        ctx.failAt(wrong_fact_detail, call.range);

        return error.UnsupportedPredicate;
    }

    return .{ .helper = .{ .id = id, .capture = binding.capture } };
}

fn compileMessage(ctx: *Compiler, message: []const u8) Error![]const fact_rule.MessageSegment {
    const raw = bytes.scanMessage(ctx.arena, message) catch return failPlaceholder(ctx);
    const tokens = raw orelse {
        const seg = try ctx.arena.alloc(fact_rule.MessageSegment, 1);
        seg[0] = .{ .literal = try ctx.arena.dupe(u8, message) };

        return seg;
    };

    const segments = try ctx.arena.alloc(fact_rule.MessageSegment, tokens.len);
    for (tokens, segments) |tok, *seg| {
        seg.* = switch (tok) {
            .literal => |s| .{ .literal = s },
            .placeholder => |inner| .{ .operand = try placeholderOperand(ctx, inner) },
        };
    }

    return segments;
}

fn placeholderOperand(ctx: *Compiler, inner: []const u8) Error!fact_rule.Operand {
    const open = std.mem.indexOfScalar(u8, inner, '(') orelse return failPlaceholder(ctx);
    if (inner.len == 0 or inner[inner.len - 1] != ')') return failPlaceholder(ctx);

    const name = inner[0..open];
    var args = std.mem.splitScalar(u8, inner[open + 1 .. inner.len - 1], ',');
    const first = std.mem.trim(u8, args.next() orelse return failPlaceholder(ctx), " ");

    if (first.len < 2 or first[0] != '@') return failPlaceholder(ctx);

    try checkSubjectName(ctx, first[1..]);

    if (std.mem.eql(u8, name, bytes.call_field)) {
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

        return .{ .field = .{ .capture = 0, .field = field } };
    }

    if (args.next() != null) return failPlaceholder(ctx);

    inline for (std.meta.fields(fact_schema.HelperId)) |helper_field| {
        const id: fact_schema.HelperId = @enumFromInt(helper_field.value);
        const descriptor_value = comptime fact_schema.descriptor(id);
        if (std.mem.eql(u8, name, descriptor_value.name)) {
            if (ctx.fact != descriptor_value.fact) {
                ctx.fail(comptime std.fmt.comptimePrint("{s} expects the {s} fact", .{
                    descriptor_value.name,
                    @tagName(descriptor_value.fact),
                }));

                return error.UnsupportedPlaceholder;
            }

            return .{ .helper = .{ .id = id, .capture = 0 } };
        }
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

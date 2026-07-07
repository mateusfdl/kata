const std = @import("std");
const ts = @import("tree_sitter");
const mvzr = @import("mvzr");

const diagnostic = @import("diagnostic.zig");
const expr = @import("expr.zig");
const language = @import("language.zig");
const message_mod = @import("message.zig");

pub const match_capture = "match";
pub const message_property = "message";
pub const exclude_paths_property = "exclude-paths";
pub const severity_property = "severity";

pub const invalid_capture_id = message_mod.invalid_capture_id;

pub const Source = enum { embedded, user, project };

pub const Format = enum { scm, kata };

pub const RawRule = struct {
    id: []const u8,
    source: []const u8,
    origin: Source = .embedded,
    format: Format = .scm,
};

pub const ScopedId = struct {
    lang: ?language.Name,
    id: []const u8,
    project: bool = false,

    pub fn matches(self: ScopedId, lang: language.Name, id: []const u8) bool {
        if (self.project) return false;

        const lang_matches = self.lang == null or self.lang.? == lang;
        return lang_matches and std.mem.eql(u8, self.id, id);
    }

    pub fn matchesProject(self: ScopedId, id: []const u8) bool {
        return self.lang == null and std.mem.eql(u8, self.id, id);
    }
};

pub fn isValidId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

pub const PredicateOp = enum {
    eq,
    not_eq,
    any_of,
    not_any_of,
    match,
    not_match,
    starts_with,
    not_starts_with,
    ends_with,
    not_ends_with,
    contains,
    not_contains,
    glob,
    not_glob,
    captured,
    not_captured,
    where,
    has,
    not_has,
    inside,
    not_inside,
    parent,
    not_parent,
    count,
    any_group,
    all_group,

    pub fn scmName(self: PredicateOp) ?[]const u8 {
        return switch (self) {
            .eq => "eq?",
            .not_eq => "not-eq?",
            .any_of => "any-of?",
            .not_any_of => "not-any-of?",
            .match => "match?",
            .not_match => "not-match?",
            .where => "where?",
            else => null,
        };
    }

    pub fn fromScmName(name: []const u8) ?PredicateOp {
        inline for (std.meta.fields(PredicateOp)) |field| {
            const op: PredicateOp = @enumFromInt(field.value);
            if (op.scmName()) |scm_name| {
                if (std.mem.eql(u8, name, scm_name)) return op;
            }
        }

        return null;
    }
};

pub const PredicateOperand = union(enum) {
    capture: u32,
    string: []const u8,
};

pub const NestedMatcher = struct {
    query: *ts.Query,
    root_capture_id: u32,
    predicates: []Predicate,
};

pub const CountCompare = struct {
    op: expr.Compare,
    value: u32,
};

pub const RegexPredicate = struct {
    args: []PredicateOperand,
    regex: mvzr.Regex,
};

pub const NestedPredicate = struct {
    args: []PredicateOperand,
    matcher: *const NestedMatcher,
};

pub const CountPredicate = struct {
    args: []PredicateOperand,
    matcher: *const NestedMatcher,
    compare: CountCompare,
};

pub const Predicate = union(PredicateOp) {
    eq: []PredicateOperand,
    not_eq: []PredicateOperand,
    any_of: []PredicateOperand,
    not_any_of: []PredicateOperand,
    match: RegexPredicate,
    not_match: RegexPredicate,
    starts_with: []PredicateOperand,
    not_starts_with: []PredicateOperand,
    ends_with: []PredicateOperand,
    not_ends_with: []PredicateOperand,
    contains: []PredicateOperand,
    not_contains: []PredicateOperand,
    glob: []PredicateOperand,
    not_glob: []PredicateOperand,
    captured: []PredicateOperand,
    not_captured: []PredicateOperand,
    where: *const expr.Expr,
    has: NestedPredicate,
    not_has: NestedPredicate,
    inside: NestedPredicate,
    not_inside: NestedPredicate,
    parent: NestedPredicate,
    not_parent: NestedPredicate,
    count: CountPredicate,
    any_group: []Predicate,
    all_group: []Predicate,
};

pub const Placeholder = message_mod.Placeholder;
pub const MessageSegment = message_mod.Segment;
pub const Message = message_mod.Message;

pub const PatternMeta = struct {
    predicates: []Predicate,
    message: ?Message,
    rule_id: []const u8,
    exclude_paths: []const []const u8 = &.{},
    severity: diagnostic.Severity = .@"error",
};

pub const CompiledRule = struct {
    query: ?*ts.Query,
    patterns: []PatternMeta,
    match_capture_id: u32,
    needs_measures: bool,
    nested_queries: []const *ts.Query = &.{},
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledRule) void {
        for (self.nested_queries) |query| query.destroy();
        if (self.query) |query| query.destroy();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

pub const CompileError = error{
    RuleCompileFailed,
    UnknownPredicate,
    InvalidPredicateOperand,
    InvalidPredicateArity,
    MissingMatchCapture,
    InvalidSetDirective,
    DuplicateSetDirective,
    InvalidRegex,
    InvalidWhereExpression,
    UnclosedPlaceholder,
    StrayBraceInMessage,
    MalformedPlaceholder,
    UnknownPlaceholderMeasure,
    UnknownPlaceholderCapture,
} || message_mod.CompileError || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    lang: ?language.Name = null,
    rule_id: []const u8 = "",
    detail: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,

    pub fn write(self: Diagnostic, prefix: []const u8, out: *std.Io.Writer) !void {
        if (self.lang) |lang| {
            try self.writeScoped(prefix, out, lang.toString(), self.rule_id);
        } else if (self.rule_id.len > 0) {
            try self.writeScoped(prefix, out, "project", self.rule_id);
        } else {
            try out.print("{s}: rule compilation failed\n", .{prefix});
        }
        try out.flush();
    }

    fn writeScoped(self: Diagnostic, prefix: []const u8, out: *std.Io.Writer, scope: []const u8, id: []const u8) !void {
        if (self.line > 0) {
            try out.print("{s}: rule {s}/{s}: line {d}, column {d}: {s}\n", .{ prefix, scope, id, self.line, self.column, self.detail });
        } else {
            try out.print("{s}: rule {s}/{s}: {s}\n", .{ prefix, scope, id, self.detail });
        }
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    lang: language.Name,
    raws: []const RawRule,
    diag: *Diagnostic,
) CompileError!CompiledRule {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var scm: std.ArrayList(RawRule) = .empty;
    for (raws) |raw| {
        if (raw.format == .scm) try scm.append(arena, raw);
    }

    if (scm.items.len == 0) {
        return .{
            .query = null,
            .patterns = &.{},
            .match_capture_id = invalid_capture_id,
            .needs_measures = false,
            .arena = arena_ptr,
            .allocator = allocator,
        };
    }

    var source: std.ArrayList(u8) = .empty;
    const rule_starts = try arena.alloc(u32, scm.items.len);
    for (scm.items, 0..) |raw, i| {
        rule_starts[i] = @intCast(source.items.len);
        try source.appendSlice(arena, raw.source);
        try source.append(arena, '\n');
    }

    var error_offset: u32 = 0;
    const query = ts.Query.create(language.grammar(lang), source.items, &error_offset) catch {
        diag.* = .{ .lang = lang, .rule_id = ownerId(rule_starts, scm.items, error_offset), .detail = "query syntax error" };
        return error.RuleCompileFailed;
    };
    errdefer query.destroy();

    const match_capture_id = captureIdForName(query, match_capture);

    const patterns = try arena.alloc(PatternMeta, query.patternCount());
    for (patterns, 0..) |*pattern, idx| {
        const owner_id = ownerId(rule_starts, scm.items, query.startByteForPattern(@intCast(idx)));
        if (!patternCapturesMatch(query, @intCast(idx), match_capture_id)) {
            diag.* = .{ .lang = lang, .rule_id = owner_id, .detail = "pattern never captures @" ++ match_capture };
            return error.MissingMatchCapture;
        }
        pattern.* = parsePattern(arena, query, @intCast(idx)) catch |err| {
            diag.* = .{ .lang = lang, .rule_id = owner_id, .detail = compileDetail(err) };
            return err;
        };
        pattern.rule_id = owner_id;
    }

    return .{
        .query = query,
        .patterns = patterns,
        .match_capture_id = match_capture_id,
        .needs_measures = needsMeasures(patterns),
        .arena = arena_ptr,
        .allocator = allocator,
    };
}

/// A pattern that never binds @match can never emit a diagnostic; reject it
/// at compile time instead of letting the rule silently do nothing.
fn patternCapturesMatch(query: *ts.Query, pattern_index: u32, match_capture_id: u32) bool {
    const quantifier = query.captureQuantifierForId(pattern_index, match_capture_id) orelse return false;
    return quantifier != .zero;
}

pub fn needsMeasures(patterns: []const PatternMeta) bool {
    for (patterns) |pattern| {
        for (pattern.predicates) |pred| {
            if (predicateNeedsMeasures(pred)) return true;
        }
        const message = pattern.message orelse continue;
        if (message == .segments) return true;
    }
    return false;
}

fn predicateNeedsMeasures(pred: Predicate) bool {
    return switch (pred) {
        .where => true,
        .has, .not_has, .inside, .not_inside, .parent, .not_parent => |nested| nestedMatcherNeedsMeasures(nested.matcher),
        .count => |count| nestedMatcherNeedsMeasures(count.matcher),
        .any_group, .all_group => |members| groupNeedsMeasures(members),
        else => false,
    };
}

fn groupNeedsMeasures(members: []const Predicate) bool {
    for (members) |member| {
        if (predicateNeedsMeasures(member)) return true;
    }
    return false;
}

fn nestedMatcherNeedsMeasures(nested: *const NestedMatcher) bool {
    for (nested.predicates) |inner| {
        if (predicateNeedsMeasures(inner)) return true;
    }
    return false;
}

fn ownerId(rule_starts: []const u32, raws: []const RawRule, offset: u32) []const u8 {
    if (raws.len == 0) return "";
    return raws[ownerIndexForPattern(rule_starts, offset)].id;
}

fn ownerIndexForPattern(rule_starts: []const u32, pattern_start: u32) usize {
    var i: usize = rule_starts.len;
    while (i > 0) {
        i -= 1;
        if (rule_starts[i] <= pattern_start) return i;
    }
    return 0;
}

pub const captureIdForName = message_mod.captureIdForName;

fn parsePattern(
    arena: std.mem.Allocator,
    query: *ts.Query,
    pattern_index: u32,
) !PatternMeta {
    const steps = query.predicatesForPattern(pattern_index);

    var predicates: std.ArrayList(Predicate) = .empty;
    var message: ?[]const u8 = null;
    var exclude_paths: []const []const u8 = &.{};
    var severity: diagnostic.Severity = .@"error";
    var severity_set = false;

    var start: usize = 0;
    for (steps, 0..) |step, idx| {
        if (step.type != .done) continue;
        try parsePredicateGroup(arena, query, steps[start..idx], &predicates, &message, &exclude_paths, &severity, &severity_set);
        start = idx + 1;
    }

    return .{
        .predicates = try predicates.toOwnedSlice(arena),
        .message = if (message) |msg| try message_mod.compile(arena, query, msg) else null,
        .rule_id = "",
        .exclude_paths = exclude_paths,
        .severity = severity,
    };
}

fn compileDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.UnclosedPlaceholder => "unclosed { in message, use {{ for a literal",
        error.StrayBraceInMessage => "stray } in message, use }} for a literal",
        error.MalformedPlaceholder => "message placeholder must be {<measure> @capture}",
        error.UnknownPlaceholderMeasure => "unknown measure in message placeholder",
        error.UnknownPlaceholderCapture => "unknown capture in message placeholder",
        error.UnknownPredicate => "unknown predicate",
        error.InvalidPredicateOperand => "invalid predicate operand",
        error.InvalidPredicateArity => "wrong number of predicate arguments",
        error.InvalidSetDirective => "invalid #set! directive",
        error.DuplicateSetDirective => "duplicate #set! directive",
        error.InvalidRegex => "invalid regex",
        error.InvalidWhereExpression => "invalid where expression",
        else => "rule compile failed",
    };
}

fn parsePredicateGroup(
    arena: std.mem.Allocator,
    query: *ts.Query,
    group: []const ts.Query.PredicateStep,
    predicates: *std.ArrayList(Predicate),
    message: *?[]const u8,
    exclude_paths: *[]const []const u8,
    severity: *diagnostic.Severity,
    severity_set: *bool,
) !void {
    const op_name = opNameFromGroup(query, group) orelse return error.RuleCompileFailed;

    if (std.mem.eql(u8, op_name, "set!")) {
        try absorbSetDirective(arena, query, group, message, exclude_paths, severity, severity_set);
        return;
    }

    try predicates.append(arena, try buildPredicate(arena, query, op_name, group));
}

fn opNameFromGroup(query: *ts.Query, group: []const ts.Query.PredicateStep) ?[]const u8 {
    if (group.len == 0) return null;
    if (group[0].type != .string) return null;

    return query.stringValueForId(group[0].value_id);
}

fn absorbSetDirective(
    arena: std.mem.Allocator,
    query: *ts.Query,
    group: []const ts.Query.PredicateStep,
    message: *?[]const u8,
    exclude_paths: *[]const []const u8,
    severity: *diagnostic.Severity,
    severity_set: *bool,
) !void {
    if (group.len != 3) return error.InvalidSetDirective;

    const key = resolveStepText(query, group[1]) orelse return error.InvalidSetDirective;
    const value = resolveStepText(query, group[2]) orelse return error.InvalidSetDirective;

    if (std.mem.eql(u8, key, message_property)) {
        if (message.* != null) return error.DuplicateSetDirective;
        message.* = value;
        return;
    }

    if (std.mem.eql(u8, key, exclude_paths_property)) {
        if (exclude_paths.*.len != 0) return error.DuplicateSetDirective;
        exclude_paths.* = try splitFields(arena, value);
        return;
    }

    if (std.mem.eql(u8, key, severity_property)) {
        if (severity_set.*) return error.DuplicateSetDirective;
        severity.* = std.meta.stringToEnum(diagnostic.Severity, value) orelse return error.InvalidSetDirective;
        severity_set.* = true;
        return;
    }

    return error.InvalidSetDirective;
}

fn splitFields(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, value, ' ');

    while (it.next()) |field| try list.append(arena, field);

    return list.toOwnedSlice(arena);
}

fn buildPredicate(
    arena: std.mem.Allocator,
    query: *ts.Query,
    op_name: []const u8,
    group: []const ts.Query.PredicateStep,
) !Predicate {
    const op = PredicateOp.fromScmName(op_name) orelse return error.UnknownPredicate;
    var args = try arena.alloc(PredicateOperand, group.len - 1);

    for (group[1..], 0..) |arg_step, j| {
        args[j] = try operandFromStep(query, arg_step);
    }

    return switch (op) {
        .eq => .{ .eq = try exactArgs(args, 2) },
        .not_eq => .{ .not_eq = try exactArgs(args, 2) },
        .any_of => .{ .any_of = try minArgs(args, 2) },
        .not_any_of => .{ .not_any_of = try minArgs(args, 2) },
        .match => .{ .match = .{ .args = args, .regex = try compileRegexArg(args) } },
        .not_match => .{ .not_match = .{ .args = args, .regex = try compileRegexArg(args) } },
        .where => .{ .where = try compileWhereArg(arena, query, args) },
        else => error.UnknownPredicate,
    };
}

fn exactArgs(args: []PredicateOperand, count: usize) CompileError![]PredicateOperand {
    if (args.len != count) return error.InvalidPredicateArity;
    return args;
}

fn minArgs(args: []PredicateOperand, count: usize) CompileError![]PredicateOperand {
    if (args.len < count) return error.InvalidPredicateArity;
    return args;
}

fn compileWhereArg(
    arena: std.mem.Allocator,
    query: *ts.Query,
    args: []const PredicateOperand,
) !*const expr.Expr {
    if (args.len != 1) return error.InvalidWhereExpression;

    const source = switch (args[0]) {
        .string => |s| s,
        .capture => return error.InvalidWhereExpression,
    };
    const resolver: QueryResolver = .{ .query = query };

    return expr.parse(arena, source, resolver) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidWhereExpression,
    };
}

const QueryResolver = struct {
    query: *ts.Query,

    pub fn captureId(self: QueryResolver, name: []const u8) ?u32 {
        const id = captureIdForName(self.query, name);
        return if (id == invalid_capture_id) null else id;
    }
};

fn compileRegexArg(args: []const PredicateOperand) !mvzr.Regex {
    if (args.len != 2) return error.InvalidPredicateArity;

    const pattern = switch (args[1]) {
        .string => |s| s,
        .capture => return error.InvalidRegex,
    };

    return mvzr.compile(pattern) orelse error.InvalidRegex;
}

fn operandFromStep(query: *ts.Query, step: ts.Query.PredicateStep) CompileError!PredicateOperand {
    return switch (step.type) {
        .capture => .{ .capture = step.value_id },
        .string => .{ .string = query.stringValueForId(step.value_id) orelse return error.InvalidPredicateOperand },
        .done => error.InvalidPredicateOperand,
    };
}

fn resolveStepText(query: *ts.Query, step: ts.Query.PredicateStep) ?[]const u8 {
    return switch (step.type) {
        .string => query.stringValueForId(step.value_id),
        .capture => query.captureNameForId(step.value_id),
        .done => null,
    };
}

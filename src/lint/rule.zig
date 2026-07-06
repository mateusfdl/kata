const std = @import("std");
const ts = @import("tree_sitter");
const mvzr = @import("mvzr");

const diagnostic = @import("diagnostic.zig");
const expr = @import("expr.zig");
const language = @import("language.zig");

pub const match_capture = "match";
pub const message_property = "message";
pub const exclude_paths_property = "exclude-paths";
pub const severity_property = "severity";

pub const invalid_capture_id: u32 = std.math.maxInt(u32);

pub const Source = enum { embedded, user, project };

pub const Format = enum { scm, kata };

pub const RawRule = struct {
    id: []const u8,
    language: language.Name,
    source: []const u8,
    origin: Source = .embedded,
    format: Format = .scm,
};

pub const ScopedId = struct {
    lang: ?language.Name,
    id: []const u8,

    pub fn matches(self: ScopedId, lang: language.Name, id: []const u8) bool {
        const lang_matches = self.lang == null or self.lang.? == lang;
        return lang_matches and std.mem.eql(u8, self.id, id);
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
    where,
};

pub const PredicateOperand = union(enum) {
    capture: u32,
    string: []const u8,
};

pub const Predicate = struct {
    op: PredicateOp,
    args: []PredicateOperand,
    regex: ?mvzr.Regex = null,
    where: ?*const expr.Expr = null,
};

pub const Placeholder = struct {
    measure: expr.Measure,
    capture_id: u32,
};

pub const MessageSegment = union(enum) {
    literal: []const u8,
    placeholder: Placeholder,
};

pub const Message = union(enum) {
    plain: []const u8,
    segments: []const MessageSegment,
};

pub const PatternMeta = struct {
    predicates: []Predicate,
    message: ?Message,
    rule_id: []const u8,
    exclude_paths: []const []const u8 = &.{},
    severity: diagnostic.Severity = .@"error",
};

pub const CompiledRule = struct {
    language: language.Name,
    query: *ts.Query,
    patterns: []PatternMeta,
    match_capture_id: u32,
    needs_measures: bool,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledRule) void {
        self.query.destroy();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

pub const CompileError = error{
    RuleCompileFailed,
    UnclosedPlaceholder,
    StrayBraceInMessage,
    MalformedPlaceholder,
    UnknownPlaceholderMeasure,
    UnknownPlaceholderCapture,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    lang: ?language.Name = null,
    rule_id: []const u8 = "",
    detail: []const u8 = "",

    pub fn write(self: Diagnostic, prefix: []const u8, out: *std.Io.Writer) !void {
        if (self.lang) |lang| {
            try out.print("{s}: rule {s}/{s}: {s}\n", .{ prefix, lang.toString(), self.rule_id, self.detail });
        } else {
            try out.print("{s}: rule compilation failed\n", .{prefix});
        }
        try out.flush();
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    lang: language.Name,
    raws: []const RawRule,
    diag: *Diagnostic,
) CompileError!CompiledRule {
    const ts_lang = registry.get(lang);

    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var source: std.ArrayList(u8) = .empty;
    const rule_starts = try arena.alloc(u32, raws.len);
    for (raws, 0..) |raw, i| {
        rule_starts[i] = @intCast(source.items.len);
        try source.appendSlice(arena, raw.source);
        try source.append(arena, '\n');
    }

    var error_offset: u32 = 0;
    const query = ts.Query.create(ts_lang, source.items, &error_offset) catch {
        diag.* = .{ .lang = lang, .rule_id = ownerId(rule_starts, raws, error_offset), .detail = "query syntax error" };
        return error.RuleCompileFailed;
    };
    errdefer query.destroy();

    const patterns = try arena.alloc(PatternMeta, query.patternCount());
    for (patterns, 0..) |*pattern, idx| {
        const owner_id = ownerId(rule_starts, raws, query.startByteForPattern(@intCast(idx)));
        pattern.* = parsePattern(arena, query, @intCast(idx)) catch |err| {
            diag.* = .{ .lang = lang, .rule_id = owner_id, .detail = compileDetail(err) };
            return err;
        };
        pattern.rule_id = owner_id;
    }

    return .{
        .language = lang,
        .query = query,
        .patterns = patterns,
        .match_capture_id = captureIdForName(query, match_capture),
        .needs_measures = anyWherePredicate(patterns) or anyMessageSegments(patterns),
        .arena = arena_ptr,
        .allocator = allocator,
    };
}

fn anyWherePredicate(patterns: []const PatternMeta) bool {
    for (patterns) |pattern| {
        for (pattern.predicates) |pred| {
            if (pred.op == .where) return true;
        }
    }
    return false;
}

fn anyMessageSegments(patterns: []const PatternMeta) bool {
    for (patterns) |pattern| {
        const message = pattern.message orelse continue;
        if (message == .segments) return true;
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

pub fn captureIdForName(query: *ts.Query, name: []const u8) u32 {
    const count = query.captureCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return invalid_capture_id;
}

fn predicateOpFromName(name: []const u8) ?PredicateOp {
    if (std.mem.eql(u8, name, "eq?")) return .eq;
    if (std.mem.eql(u8, name, "not-eq?")) return .not_eq;
    if (std.mem.eql(u8, name, "any-of?")) return .any_of;
    if (std.mem.eql(u8, name, "not-any-of?")) return .not_any_of;
    if (std.mem.eql(u8, name, "match?")) return .match;
    if (std.mem.eql(u8, name, "not-match?")) return .not_match;
    if (std.mem.eql(u8, name, "where?")) return .where;
    return null;
}

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

    var start: usize = 0;
    for (steps, 0..) |step, idx| {
        if (step.type != .done) continue;
        try parsePredicateGroup(arena, query, steps[start..idx], &predicates, &message, &exclude_paths, &severity);
        start = idx + 1;
    }

    return .{
        .predicates = try predicates.toOwnedSlice(arena),
        .message = if (message) |msg| try compileMessage(arena, query, msg) else null,
        .rule_id = "",
        .exclude_paths = exclude_paths,
        .severity = severity,
    };
}

fn compileMessage(
    arena: std.mem.Allocator,
    query: *ts.Query,
    message: []const u8,
) CompileError!Message {
    const segments = (try compileMessageSegments(arena, query, message)) orelse
        return .{ .plain = message };
    if (segments.len == 1 and segments[0] == .literal) return .{ .plain = segments[0].literal };
    return .{ .segments = segments };
}

fn compileDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.UnclosedPlaceholder => "unclosed { in message, use {{ for a literal",
        error.StrayBraceInMessage => "stray } in message, use }} for a literal",
        error.MalformedPlaceholder => "message placeholder must be {<measure> @capture}",
        error.UnknownPlaceholderMeasure => "unknown measure in message placeholder",
        error.UnknownPlaceholderCapture => "unknown capture in message placeholder",
        else => "unsupported predicate, #set! key, regex, or where expression",
    };
}

fn compileMessageSegments(
    arena: std.mem.Allocator,
    query: *ts.Query,
    message: []const u8,
) CompileError!?[]const MessageSegment {
    if (std.mem.indexOfAny(u8, message, "{}") == null) return null;

    var segments: std.ArrayList(MessageSegment) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < message.len) {
        const c = message[i];
        if (c == '{') {
            if (i + 1 < message.len and message[i + 1] == '{') {
                try literal.append(arena, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, message, i + 1, '}') orelse
                return error.UnclosedPlaceholder;
            if (literal.items.len > 0)
                try segments.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });
            try segments.append(arena, .{ .placeholder = try parsePlaceholder(query, message[i + 1 .. close]) });
            i = close + 1;
            continue;
        }
        if (c == '}') {
            if (i + 1 < message.len and message[i + 1] == '}') {
                try literal.append(arena, '}');
                i += 2;
                continue;
            }
            return error.StrayBraceInMessage;
        }
        try literal.append(arena, c);
        i += 1;
    }
    if (literal.items.len > 0)
        try segments.append(arena, .{ .literal = try literal.toOwnedSlice(arena) });
    return try segments.toOwnedSlice(arena);
}

fn parsePlaceholder(query: *ts.Query, inner: []const u8) CompileError!Placeholder {
    var it = std.mem.tokenizeScalar(u8, inner, ' ');
    const measure_name = it.next() orelse return error.MalformedPlaceholder;
    const capture = it.next() orelse return error.MalformedPlaceholder;
    if (it.next() != null) return error.MalformedPlaceholder;

    const measure = expr.Measure.fromString(measure_name) orelse return error.UnknownPlaceholderMeasure;
    if (capture.len < 2 or capture[0] != '@') return error.MalformedPlaceholder;
    const resolver: QueryResolver = .{ .query = query };
    const id = resolver.captureId(capture[1..]) orelse return error.UnknownPlaceholderCapture;
    return .{ .measure = measure, .capture_id = id };
}

fn parsePredicateGroup(
    arena: std.mem.Allocator,
    query: *ts.Query,
    group: []const ts.Query.PredicateStep,
    predicates: *std.ArrayList(Predicate),
    message: *?[]const u8,
    exclude_paths: *[]const []const u8,
    severity: *diagnostic.Severity,
) !void {
    const op_name = opNameFromGroup(query, group) orelse return;

    if (std.mem.eql(u8, op_name, "set!")) {
        try absorbSetDirective(arena, query, group, message, exclude_paths, severity);
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
) !void {
    if (group.len < 3) return error.RuleCompileFailed;
    const key = resolveStepText(query, group[1]) orelse return error.RuleCompileFailed;
    const value = resolveStepText(query, group[2]) orelse return error.RuleCompileFailed;

    if (std.mem.eql(u8, key, message_property)) {
        if (message.* == null) message.* = value;
        return;
    }
    if (std.mem.eql(u8, key, exclude_paths_property)) {
        if (exclude_paths.*.len == 0) exclude_paths.* = try splitFields(arena, value);
        return;
    }
    if (std.mem.eql(u8, key, severity_property)) {
        severity.* = std.meta.stringToEnum(diagnostic.Severity, value) orelse return error.RuleCompileFailed;
        return;
    }
    return error.RuleCompileFailed;
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
    var args = try arena.alloc(PredicateOperand, group.len - 1);
    for (group[1..], 0..) |arg_step, j| {
        args[j] = operandFromStep(query, arg_step);
    }
    const op = predicateOpFromName(op_name) orelse return error.RuleCompileFailed;
    return .{
        .op = op,
        .args = args,
        .regex = try compileRegexArg(op, args),
        .where = try compileWhereArg(arena, query, op, args),
    };
}

fn compileWhereArg(
    arena: std.mem.Allocator,
    query: *ts.Query,
    op: PredicateOp,
    args: []const PredicateOperand,
) !?*const expr.Expr {
    if (op != .where) return null;
    if (args.len != 1) return error.RuleCompileFailed;
    const source = switch (args[0]) {
        .string => |s| s,
        .capture => return error.RuleCompileFailed,
    };
    const resolver: QueryResolver = .{ .query = query };
    return expr.parse(arena, source, resolver) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RuleCompileFailed,
    };
}

const QueryResolver = struct {
    query: *ts.Query,

    pub fn captureId(self: QueryResolver, name: []const u8) ?u32 {
        const id = captureIdForName(self.query, name);
        return if (id == invalid_capture_id) null else id;
    }
};

fn compileRegexArg(op: PredicateOp, args: []const PredicateOperand) !?mvzr.Regex {
    if (op != .match and op != .not_match) return null;
    if (args.len != 2) return error.RuleCompileFailed;
    const pattern = switch (args[1]) {
        .string => |s| s,
        .capture => return error.RuleCompileFailed,
    };
    return mvzr.compile(pattern) orelse error.RuleCompileFailed;
}

fn operandFromStep(query: *ts.Query, step: ts.Query.PredicateStep) PredicateOperand {
    return switch (step.type) {
        .capture => .{ .capture = step.value_id },
        .string => .{ .string = query.stringValueForId(step.value_id) orelse "" },
        .done => .{ .string = "" },
    };
}

fn resolveStepText(query: *ts.Query, step: ts.Query.PredicateStep) ?[]const u8 {
    return switch (step.type) {
        .string => query.stringValueForId(step.value_id),
        .capture => query.captureNameForId(step.value_id),
        .done => null,
    };
}

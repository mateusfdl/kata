const std = @import("std");
const ts = @import("tree_sitter");

const language = @import("language.zig");

pub const match_capture = "match";
pub const message_property = "message";

pub const invalid_capture_id: u32 = std.math.maxInt(u32);

pub const RawRule = struct {
    id: []const u8,
    language: language.Name,
    source: []const u8,
};

pub const PredicateOp = enum {
    eq,
    not_eq,
    any_of,
    not_any_of,
    unknown,
};

pub const PredicateOperand = union(enum) {
    capture: u32,
    string: []const u8,
};

pub const Predicate = struct {
    op: PredicateOp,
    args: []PredicateOperand,
};

pub const PatternMeta = struct {
    predicates: []Predicate,
    message: ?[]const u8,
    rule_id: []const u8,
};

pub const CompiledRule = struct {
    language: language.Name,
    query: *ts.Query,
    patterns: []PatternMeta,
    match_capture_id: u32,
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
} || std.mem.Allocator.Error;

pub fn compile(
    allocator: std.mem.Allocator,
    registry: *language.Registry,
    raws: []const RawRule,
) CompileError![]CompiledRule {
    if (raws.len == 0) return allocator.alloc(CompiledRule, 0);

    const ts_lang = registry.get(raws[0].language);

    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    var source: std.ArrayList(u8) = .empty;
    for (raws) |raw| {
        try source.appendSlice(arena, raw.source);
        try source.append(arena, '\n');
    }

    var error_offset: u32 = 0;
    const query = ts.Query.create(ts_lang, source.items, &error_offset) catch
        return error.RuleCompileFailed;
    errdefer query.destroy();

    const total = query.patternCount();
    const owners = try arena.alloc([]const u8, total);
    var gp: u32 = 0;
    for (raws) |raw| {
        var raw_offset: u32 = 0;
        const probe = ts.Query.create(ts_lang, raw.source, &raw_offset) catch
            return error.RuleCompileFailed;
        const count = probe.patternCount();
        probe.destroy();
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            if (gp >= total) return error.RuleCompileFailed;
            owners[gp] = raw.id;
            gp += 1;
        }
    }
    if (gp != total) return error.RuleCompileFailed;

    const patterns = try buildPatternMeta(arena, query);
    for (patterns, owners) |*pattern, owner| pattern.rule_id = owner;

    var out = try allocator.alloc(CompiledRule, 1);
    out[0] = .{
        .language = raws[0].language,
        .query = query,
        .patterns = patterns,
        .match_capture_id = captureIdForName(query, match_capture),
        .arena = arena_ptr,
        .allocator = allocator,
    };
    return out;
}

fn captureIdForName(query: *ts.Query, name: []const u8) u32 {
    const count = query.captureCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return invalid_capture_id;
}

fn predicateOpFromName(name: []const u8) PredicateOp {
    if (std.mem.eql(u8, name, "eq?")) return .eq;
    if (std.mem.eql(u8, name, "not-eq?")) return .not_eq;
    if (std.mem.eql(u8, name, "any-of?")) return .any_of;
    if (std.mem.eql(u8, name, "not-any-of?")) return .not_any_of;
    return .unknown;
}

fn buildPatternMeta(arena: std.mem.Allocator, query: *ts.Query) ![]PatternMeta {
    const pattern_count = query.patternCount();
    var patterns = try arena.alloc(PatternMeta, pattern_count);

    var p: u32 = 0;
    while (p < pattern_count) : (p += 1) {
        patterns[p] = try parsePattern(arena, query, p);
    }
    return patterns;
}

fn parsePattern(
    arena: std.mem.Allocator,
    query: *ts.Query,
    pattern_index: u32,
) !PatternMeta {
    const steps = query.predicatesForPattern(pattern_index);

    var predicates: std.ArrayList(Predicate) = .empty;
    var message: ?[]const u8 = null;

    var start: usize = 0;
    for (steps, 0..) |step, idx| {
        if (step.type != .done) continue;
        try parsePredicateGroup(arena, query, steps[start..idx], &predicates, &message);
        start = idx + 1;
    }

    return .{
        .predicates = try predicates.toOwnedSlice(arena),
        .message = message,
        .rule_id = "",
    };
}

fn parsePredicateGroup(
    arena: std.mem.Allocator,
    query: *ts.Query,
    group: []const ts.Query.PredicateStep,
    predicates: *std.ArrayList(Predicate),
    message: *?[]const u8,
) !void {
    const op_name = opNameFromGroup(query, group) orelse return;

    if (std.mem.eql(u8, op_name, "set!")) {
        absorbSetDirective(query, group, message);
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
    query: *ts.Query,
    group: []const ts.Query.PredicateStep,
    message: *?[]const u8,
) void {
    if (message.* != null) return;
    if (group.len < 2) return;
    const key = resolveStepText(query, group[1]) orelse return;
    if (!std.mem.eql(u8, key, message_property)) return;
    if (group.len < 3) return;
    message.* = resolveStepText(query, group[2]);
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
    return .{
        .op = predicateOpFromName(op_name),
        .args = args,
    };
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

pub fn destroyCompiled(allocator: std.mem.Allocator, rules: []CompiledRule) void {
    for (rules) |*r| r.deinit();
    allocator.free(rules);
}

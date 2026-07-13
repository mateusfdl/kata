const std = @import("std");
const mvzr = @import("mvzr");

const diagnostic = @import("diagnostic.zig");
const expr = @import("expr.zig");
const language = @import("language.zig");
const message_mod = @import("message.zig");
const query = @import("query.zig");

pub const match_capture = "match";

pub const Source = enum { embedded, user, project };

pub const RawRule = struct {
    id: []const u8,
    source: []const u8,
    origin: Source = .embedded,
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
};

pub const PredicateOperand = union(enum) {
    capture: query.CaptureId,
    string: []const u8,
};

pub const NestedMatcher = struct {
    pattern: query.Pattern,
    capture_count: usize,
    root_capture_id: query.CaptureId,
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
    until_kinds: []const u16 = &.{},
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

pub const CompiledPattern = struct {
    pattern: query.Pattern,
    capture_count: usize,
    match_capture_id: ?query.CaptureId,
    meta: PatternMeta,
};

pub const CompiledRule = struct {
    patterns: []CompiledPattern,
    needs_measures: bool,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledRule) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

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

pub fn needsMeasures(patterns: []const CompiledPattern) bool {
    for (patterns) |cp| {
        for (cp.meta.predicates) |pred| {
            if (predicateNeedsMeasures(pred)) return true;
        }
        const message = cp.meta.message orelse continue;
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

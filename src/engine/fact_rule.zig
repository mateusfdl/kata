const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const fact_query = @import("fact_query.zig");
const facts = @import("facts.zig");
const fact_schema = @import("fact_schema.zig");
const glob = @import("glob.zig");
const project_rule = @import("ProjectRule.zig");
const rule = @import("rule.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const Violation = project_rule.Violation;

pub const FactKind = fact_schema.FactKind;
pub const Field = fact_schema.Field;
pub const Fact = fact_schema.Fact;
pub const factHasField = fact_schema.factHasField;

pub const CaptureId = fact_query.CaptureId;
pub const CaptureSet = fact_query.CaptureSet;
pub const FieldOperand = fact_query.FieldOperand;
pub const HelperOperand = fact_query.HelperOperand;
pub const Operand = fact_query.Operand;
pub const Op = fact_query.Op;
pub const ScalarPredicate = fact_query.ScalarPredicate;
pub const FactQuery = fact_query.FactQuery;
pub const CountCompare = fact_query.CountCompare;
pub const CountPredicate = fact_query.CountPredicate;
pub const Predicate = fact_query.Predicate;
pub const Group = fact_query.Group;

const BoundFact = fact_query.BoundFact;
const Context = fact_query.Context;

pub const MessageSegment = union(enum) {
    literal: []const u8,
    operand: Operand,
};

pub const CompiledFactRule = struct {
    id: []const u8,
    fact: FactKind,
    capture_count: usize = 1,
    predicates: []const Predicate,
    message: []const MessageSegment,
    severity: diagnostic.Severity = .@"error",
    maturity: diagnostic.Maturity = .stable,
    exclude_paths: []const []const u8 = &.{},
};

pub fn fieldFromString(name: []const u8) ?Field {
    return std.meta.stringToEnum(Field, name);
}

/// Evaluate fact rules against the index. `path_filter` restricts the output
/// to violations in that file while still using the whole index for
/// cross-file context (class names) — a violation is always attributed to the
/// file containing the fact, so other files never need per-fact evaluation.
pub fn evaluate(
    allocator: std.mem.Allocator,
    rules: []const CompiledFactRule,
    settings: []const rule.RuleSetting,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(allocator);

    try evaluateInto(allocator, rules, settings, index, path_filter, &out);

    std.mem.sort(Violation, out.items, {}, project_rule.violationLessThan);
    return out.toOwnedSlice(allocator);
}

pub fn evaluateInto(
    allocator: std.mem.Allocator,
    rules: []const CompiledFactRule,
    settings: []const rule.RuleSetting,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
    out: *std.ArrayList(Violation),
) !void {
    var class_names: std.StringHashMapUnmanaged(void) = .empty;
    defer class_names.deinit(allocator);
    if (needsClassIndex(rules)) try collectClassNames(allocator, index, &class_names);

    const ctx: Context = .{
        .allocator = allocator,
        .index = index,
        .class_names = &class_names,
    };

    if (path_filter) |path| {
        if (index.get(path)) |file| {
            for (rules) |r| try evaluateFile(out, allocator, r, settings, ctx, file);
        }
    } else {
        for (rules) |r| {
            var files = index.fileIterator();
            while (files.next()) |file| {
                try evaluateFile(out, allocator, r, settings, ctx, file);
            }
        }
    }
}

fn needsClassIndex(rules: []const CompiledFactRule) bool {
    for (rules) |compiled| {
        if (predicatesNeedClassIndex(compiled.predicates)) return true;
        for (compiled.message) |segment| {
            switch (segment) {
                .operand => |operand| if (operandNeedsClassIndex(operand)) return true,
                .literal => {},
            }
        }
    }

    return false;
}

fn predicatesNeedClassIndex(predicates: []const Predicate) bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .scalar => |scalar| for (scalar.args) |operand| {
                if (operandNeedsClassIndex(operand)) return true;
            },
            .all_group, .any_group => |group| if (predicatesNeedClassIndex(group.members)) return true,
            .exists, .not_exists => |query| if (predicatesNeedClassIndex(query.predicates)) return true,
            .count => |count| if (predicatesNeedClassIndex(count.query.predicates)) return true,
        }
    }

    return false;
}

fn operandNeedsClassIndex(operand: Operand) bool {
    return switch (operand) {
        .helper => |helper| switch (helper.id) {
            inline else => |id| fact_schema.descriptor(id).needs_class_index,
        },
        .field, .literal => false,
    };
}

fn collectClassNames(
    allocator: std.mem.Allocator,
    index: *const ProjectIndex,
    class_names: *std.StringHashMapUnmanaged(void),
) !void {
    var files = index.fileIterator();
    while (files.next()) |file| {
        for (file.classes) |class_def| try class_names.put(allocator, class_def.name, {});
    }
}

const EvaluateFactSink = struct {
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    rule_value: CompiledFactRule,
    ctx: Context,
    bindings: []?BoundFact,

    pub fn visit(self: *EvaluateFactSink, file: *const facts.FileFacts, fact: Fact) std.mem.Allocator.Error!fact_schema.VisitControl {
        try evaluateFact(self.out, self.allocator, self.rule_value, self.ctx, self.bindings, .{ .fact = fact, .file = file });
        return .continue_scan;
    }
};

fn evaluateFile(
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    r: CompiledFactRule,
    settings: []const rule.RuleSetting,
    ctx: Context,
    file: *const facts.FileFacts,
) !void {
    for (r.exclude_paths) |pattern| {
        if (glob.match(pattern, file.path)) return;
    }

    const policy = rule.resolvePolicy(settings, .project, r.id, file.path);
    if (!policy.enabled or policy.excluded) return;
    var configured = r;
    configured.severity = policy.severity orelse r.severity;

    const bindings = try ctx.allocator.alloc(?BoundFact, configured.capture_count);
    defer ctx.allocator.free(bindings);
    @memset(bindings, null);

    var sink: EvaluateFactSink = .{
        .out = out,
        .allocator = allocator,
        .rule_value = configured,
        .ctx = ctx,
        .bindings = bindings,
    };
    _ = try fact_schema.visitFacts(file, configured.fact, &sink);
}

fn evaluateFact(
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    r: CompiledFactRule,
    ctx: Context,
    bindings: []?BoundFact,
    root: BoundFact,
) !void {
    bindings[0] = root;
    if (try fact_query.evaluate(r.predicates, ctx, bindings) != .yes) return;

    try out.append(allocator, .{
        .path = root.file.path,
        .diagnostic = .{
            .rule_id = r.id,
            .language = root.file.lang.toString(),
            .rule_scope = .project,
            .severity = r.severity,
            .maturity = r.maturity,
            .message = try renderMessage(allocator, r.message, ctx, bindings),
            .range = factRange(root.fact),
        },
    });
}

fn renderMessage(
    allocator: std.mem.Allocator,
    segments: []const MessageSegment,
    ctx: Context,
    bindings: []?BoundFact,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(allocator, text),
            .operand => |operand| {
                const value = (try fact_query.resolveOperand(operand, ctx, bindings)) orelse "?";
                try out.appendSlice(allocator, value);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn factRange(fact: Fact) diagnostic.Range {
    return switch (fact) {
        inline else => |f| f.range,
    };
}

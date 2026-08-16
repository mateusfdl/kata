const std = @import("std");

const compiled_rule = @import("compiled_rule.zig");
const context_query = @import("context_query.zig");
const diagnostic = @import("../diagnostic.zig");
const facts = @import("../facts.zig");
const fact_schema = @import("../fact_schema.zig");
const glob = @import("../glob.zig");
const message_rule = @import("message_rule.zig");
const predicate_query = @import("predicate_query.zig");
const project_rule = @import("../ProjectRule.zig");
const rule = @import("../rule.zig");

const ProjectIndex = @import("../ProjectIndex.zig").ProjectIndex;

const BoundFact = context_query.BoundFact;
const CompiledFactRule = compiled_rule.CompiledFactRule;
const Context = context_query.Context;
const Predicate = predicate_query.Predicate;
const Violation = project_rule.Violation;

const EvaluateFactSink = struct {
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    rule_value: CompiledFactRule,
    ctx: Context,
    bindings: []?BoundFact,

    pub fn visit(self: *EvaluateFactSink, file: *const facts.FileFacts, fact: fact_schema.Fact) std.mem.Allocator.Error!fact_schema.VisitControl {
        try evaluateFact(self.out, self.allocator, self.rule_value, self.ctx, self.bindings, .{ .fact = fact, .file = file });
        return .continue_scan;
    }
};

/// Evaluate fact rules against the index. `path_filter` restricts the output
/// to violations in that file while still using the whole index for
/// cross-file context (class names) - a violation is always attributed to the
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
                .operand => |operand| if (operand.needsClassIndex()) return true,
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
                if (operand.needsClassIndex()) return true;
            },
            .all_group, .any_group => |group| if (predicatesNeedClassIndex(group.members)) return true,
            .exists, .not_exists => |query| if (predicatesNeedClassIndex(query.predicates)) return true,
            .count => |count| if (predicatesNeedClassIndex(count.query.predicates)) return true,
        }
    }

    return false;
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
    if (try predicate_query.evaluate(r.predicates, ctx, bindings) != .yes) return;

    try out.append(allocator, .{
        .path = root.file.path,
        .diagnostic = .{
            .rule_id = r.id,
            .language = root.file.lang.toString(),
            .rule_scope = .project,
            .severity = r.severity,
            .maturity = r.maturity,
            .message = try message_rule.render(allocator, r.message, ctx, bindings),
            .range = factRange(root.fact),
        },
    });
}

fn factRange(fact: fact_schema.Fact) diagnostic.Range {
    return switch (fact) {
        inline else => |f| f.range,
    };
}

const std = @import("std");
const mvzr = @import("mvzr");

const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");
const glob = @import("glob.zig");
const project_rule = @import("ProjectRule.zig");
const rule = @import("rule.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const ScopedId = rule.ScopedId;
pub const Violation = project_rule.Violation;

pub const FactKind = enum {
    class,
    method,
    typed_decl,
    call,
    import,

    pub fn fromString(name: []const u8) ?FactKind {
        inline for (std.meta.fields(FactKind)) |field| {
            const kind: FactKind = @enumFromInt(field.value);
            if (std.mem.eql(u8, name, kind.toString())) return kind;
        }

        return null;
    }

    pub fn toString(self: FactKind) []const u8 {
        return switch (self) {
            .class => "class",
            .method => "method",
            .typed_decl => "typedDecl",
            .call => "call",
            .import => "import",
        };
    }
};

pub const Field = enum {
    name,
    container,
    type,
    receiver,
    method,
    source,
    path,
    lang,
};

pub const Operand = union(enum) {
    field: Field,
    literal: []const u8,
    receiver_type,
    resolved_import_source,
};

pub const Op = enum {
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
};

pub const Predicate = struct {
    op: Op,
    args: []const Operand,
    regex: ?mvzr.Regex = null,
};

pub const MessageSegment = union(enum) {
    literal: []const u8,
    operand: Operand,
};

pub const CompiledFactRule = struct {
    id: []const u8,
    fact: FactKind,
    predicates: []const Predicate,
    message: []const MessageSegment,
    severity: diagnostic.Severity = .@"error",
    exclude_paths: []const []const u8 = &.{},
};

pub fn fieldFromString(name: []const u8) ?Field {
    return std.meta.stringToEnum(Field, name);
}

pub fn factHasField(kind: FactKind, field: Field) bool {
    if (field == .path or field == .lang) return true;

    return switch (kind) {
        .class => field == .name,
        .method => field == .name or field == .container,
        .typed_decl => field == .name or field == .type,
        .call => field == .receiver or field == .method or field == .container,
        .import => field == .name or field == .source,
    };
}

const Fact = union(FactKind) {
    class: facts.ClassDef,
    method: facts.MethodDef,
    typed_decl: facts.TypedDecl,
    call: facts.Call,
    import: facts.Import,
};

const Context = struct {
    allocator: std.mem.Allocator,
    file: *const facts.FileFacts,
    class_names: *const std.StringHashMapUnmanaged(void),
};

/// Evaluate fact rules against the index. `path_filter` restricts the output
/// to violations in that file while still using the whole index for
/// cross-file context (class names) — a violation is always attributed to the
/// file containing the fact, so other files never need per-fact evaluation.
pub fn evaluate(
    allocator: std.mem.Allocator,
    rules: []const CompiledFactRule,
    warnings: []const ScopedId,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(allocator);

    var class_names: std.StringHashMapUnmanaged(void) = .empty;
    defer class_names.deinit(allocator);
    if (needsClassIndex(rules)) try collectClassNames(allocator, index, &class_names);

    if (path_filter) |path| {
        if (index.get(path)) |file| {
            const ctx: Context = .{ .allocator = allocator, .file = file, .class_names = &class_names };
            for (rules) |r| try evaluateFile(&out, allocator, r, ctx);
        }
    } else {
        for (rules) |r| {
            var files = index.files.valueIterator();
            while (files.next()) |file| {
                const ctx: Context = .{ .allocator = allocator, .file = file, .class_names = &class_names };
                try evaluateFile(&out, allocator, r, ctx);
            }
        }
    }

    for (out.items) |*v| {
        if (matchesWarning(warnings, v.diagnostic.rule_id)) v.diagnostic.severity = .warn;
    }

    std.mem.sort(Violation, out.items, {}, project_rule.violationLessThan);

    return out.toOwnedSlice(allocator);
}

fn matchesWarning(warnings: []const ScopedId, id: []const u8) bool {
    for (warnings) |w| {
        if (w.matchesProject(id)) return true;
    }

    return false;
}

fn needsClassIndex(rules: []const CompiledFactRule) bool {
    for (rules) |r| {
        for (r.predicates) |pred| {
            for (pred.args) |arg| {
                if (arg == .receiver_type) return true;
            }
        }
        for (r.message) |segment| {
            switch (segment) {
                .operand => |operand| if (operand == .receiver_type) return true,
                .literal => {},
            }
        }
    }

    return false;
}

fn collectClassNames(
    allocator: std.mem.Allocator,
    index: *const ProjectIndex,
    class_names: *std.StringHashMapUnmanaged(void),
) !void {
    var files = index.files.valueIterator();
    while (files.next()) |file| {
        for (file.classes) |class_def| try class_names.put(allocator, class_def.name, {});
    }
}

fn evaluateFile(
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    r: CompiledFactRule,
    ctx: Context,
) !void {
    for (r.exclude_paths) |pattern| {
        if (glob.match(pattern, ctx.file.path)) return;
    }

    switch (r.fact) {
        .class => for (ctx.file.classes) |c| try evaluateFact(out, allocator, r, ctx, .{ .class = c }),
        .method => for (ctx.file.methods) |m| try evaluateFact(out, allocator, r, ctx, .{ .method = m }),
        .typed_decl => for (ctx.file.typed_decls) |d| try evaluateFact(out, allocator, r, ctx, .{ .typed_decl = d }),
        .call => for (ctx.file.calls) |c| try evaluateFact(out, allocator, r, ctx, .{ .call = c }),
        .import => for (ctx.file.imports) |i| try evaluateFact(out, allocator, r, ctx, .{ .import = i }),
    }
}

fn evaluateFact(
    out: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    r: CompiledFactRule,
    ctx: Context,
    fact: Fact,
) !void {
    for (r.predicates) |pred| {
        if (!try evalPredicate(pred, ctx, fact)) return;
    }

    try out.append(allocator, .{
        .path = ctx.file.path,
        .diagnostic = .{
            .rule_id = r.id,
            .language = ctx.file.lang.toString(),
            .severity = r.severity,
            .message = try renderMessage(allocator, r.message, ctx, fact),
            .range = factRange(fact),
        },
    });
}

fn evalPredicate(pred: Predicate, ctx: Context, fact: Fact) std.mem.Allocator.Error!bool {
    return switch (pred.op) {
        .eq => try evalEq(pred, ctx, fact, false),
        .not_eq => try evalEq(pred, ctx, fact, true),
        .any_of => try evalAnyOf(pred, ctx, fact, false),
        .not_any_of => try evalAnyOf(pred, ctx, fact, true),
        .match => try evalMatch(pred, ctx, fact, false),
        .not_match => try evalMatch(pred, ctx, fact, true),
        .starts_with => try evalStringHelper(pred, ctx, fact, .starts_with, false),
        .not_starts_with => try evalStringHelper(pred, ctx, fact, .starts_with, true),
        .ends_with => try evalStringHelper(pred, ctx, fact, .ends_with, false),
        .not_ends_with => try evalStringHelper(pred, ctx, fact, .ends_with, true),
        .contains => try evalStringHelper(pred, ctx, fact, .contains, false),
        .not_contains => try evalStringHelper(pred, ctx, fact, .contains, true),
        .glob => try evalStringHelper(pred, ctx, fact, .glob, false),
        .not_glob => try evalStringHelper(pred, ctx, fact, .glob, true),
    };
}

fn evalEq(pred: Predicate, ctx: Context, fact: Fact, negate: bool) std.mem.Allocator.Error!bool {
    if (pred.args.len != 2) return false;

    const left = (try resolveOperand(pred.args[0], ctx, fact)) orelse return false;
    const right = (try resolveOperand(pred.args[1], ctx, fact)) orelse return false;

    return std.mem.eql(u8, left, right) != negate;
}

fn evalAnyOf(pred: Predicate, ctx: Context, fact: Fact, negate: bool) std.mem.Allocator.Error!bool {
    if (pred.args.len < 2) return false;

    const left = (try resolveOperand(pred.args[0], ctx, fact)) orelse return false;
    for (pred.args[1..]) |arg| {
        const candidate = (try resolveOperand(arg, ctx, fact)) orelse continue;
        if (std.mem.eql(u8, left, candidate)) return !negate;
    }

    return negate;
}

fn evalMatch(pred: Predicate, ctx: Context, fact: Fact, negate: bool) std.mem.Allocator.Error!bool {
    const re = pred.regex orelse return false;
    if (pred.args.len != 1) return false;

    const text = (try resolveOperand(pred.args[0], ctx, fact)) orelse return false;

    return re.isMatch(text) != negate;
}

const StringHelper = enum { starts_with, ends_with, contains, glob };

fn evalStringHelper(
    pred: Predicate,
    ctx: Context,
    fact: Fact,
    helper: StringHelper,
    negate: bool,
) std.mem.Allocator.Error!bool {
    if (pred.args.len != 2) return false;

    const subject = (try resolveOperand(pred.args[0], ctx, fact)) orelse return false;
    const candidate = (try resolveOperand(pred.args[1], ctx, fact)) orelse return false;
    const found = switch (helper) {
        .starts_with => std.mem.startsWith(u8, subject, candidate),
        .ends_with => std.mem.endsWith(u8, subject, candidate),
        .contains => std.mem.indexOf(u8, subject, candidate) != null,
        .glob => glob.match(candidate, subject),
    };

    return found != negate;
}

fn renderMessage(
    allocator: std.mem.Allocator,
    segments: []const MessageSegment,
    ctx: Context,
    fact: Fact,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(allocator, text),
            .operand => |operand| {
                const value = (try resolveOperand(operand, ctx, fact)) orelse "?";
                try out.appendSlice(allocator, value);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn resolveOperand(operand: Operand, ctx: Context, fact: Fact) std.mem.Allocator.Error!?[]const u8 {
    return switch (operand) {
        .literal => |s| s,
        .field => |f| fieldValue(fact, f, ctx.file),
        .receiver_type => receiverType(ctx, fact),
        .resolved_import_source => try resolvedImportSource(ctx, fact),
    };
}

fn fieldValue(fact: Fact, field: Field, file: *const facts.FileFacts) ?[]const u8 {
    switch (field) {
        .path => return file.path,
        .lang => return file.lang.toString(),
        else => {},
    }

    return switch (fact) {
        .class => |c| switch (field) {
            .name => c.name,
            else => null,
        },
        .method => |m| switch (field) {
            .name => m.name,
            .container => m.container,
            else => null,
        },
        .typed_decl => |d| switch (field) {
            .name => d.name,
            .type => d.type_name,
            else => null,
        },
        .call => |c| switch (field) {
            .receiver => c.receiver,
            .method => c.method,
            .container => c.container,
            else => null,
        },
        .import => |i| switch (field) {
            .name => i.name,
            .source => i.source,
            else => null,
        },
    };
}

fn receiverType(ctx: Context, fact: Fact) ?[]const u8 {
    const call = switch (fact) {
        .call => |c| c,
        else => return null,
    };
    const resolved = facts.receiverType(ctx.file, call.receiver) orelse return null;
    if (!ctx.class_names.contains(resolved)) return null;

    return resolved;
}

fn resolvedImportSource(ctx: Context, fact: Fact) std.mem.Allocator.Error!?[]const u8 {
    const im = switch (fact) {
        .import => |i| i,
        else => return null,
    };

    return facts.resolveImportSource(ctx.allocator, ctx.file.lang.family(), ctx.file.path, im.source);
}

fn factRange(fact: Fact) diagnostic.Range {
    return switch (fact) {
        inline else => |f| f.range,
    };
}

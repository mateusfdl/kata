const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const ProjectRule = struct {
    id: []const u8,
    kind: Kind,

    pub const RestrictedCallers = struct {
        callee_suffix: []const u8,
        caller_suffix: []const u8,
    };

    pub const ImportBoundary = struct {
        from: []const u8,
        deny: []const u8,
    };

    pub const Kind = union(enum) {
        restricted_callers: RestrictedCallers,
        import_boundary: ImportBoundary,

        pub const Tag = std.meta.Tag(Kind);

        pub fn tagFromString(s: []const u8) ?Tag {
            if (std.mem.eql(u8, s, "restricted-callers")) return .restricted_callers;
            if (std.mem.eql(u8, s, "import-boundary")) return .import_boundary;
            return null;
        }
    };
};

pub const Violation = struct {
    path: []const u8,
    diagnostic: diagnostic.Diagnostic,
};

/// evaluate project rules against the index. `path_filter` restricts the
/// output to violations in that file while still using the whole index for
/// cross-file context (callee types), violations are always attributed to
/// the file containing the offending call or import.
pub fn evaluate(
    allocator: std.mem.Allocator,
    rules: []const ProjectRule,
    settings: []const rule.RuleSetting,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(allocator);

    try evaluateInto(allocator, rules, settings, index, path_filter, &out);

    std.mem.sort(Violation, out.items, {}, violationLessThan);
    return out.toOwnedSlice(allocator);
}

pub fn evaluateInto(
    allocator: std.mem.Allocator,
    rules: []const ProjectRule,
    settings: []const rule.RuleSetting,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
    out: *std.ArrayList(Violation),
) !void {
    const start = out.items.len;

    for (rules) |project| {
        switch (project.kind) {
            .restricted_callers => |rc| try evaluateRestrictedCallers(allocator, project.id, rc, index, path_filter, out),
            .import_boundary => |ib| try evaluateImportBoundary(allocator, project.id, ib, index, path_filter, out),
        }
    }

    var i: usize = start;
    while (i < out.items.len) {
        const policy = rule.resolvePolicy(settings, .project, out.items[i].diagnostic.rule_id, out.items[i].path);
        if (!policy.enabled or policy.excluded) {
            _ = out.swapRemove(i);
        } else {
            if (policy.severity) |severity| out.items[i].diagnostic.severity = severity;
            i += 1;
        }
    }
}

fn evaluateRestrictedCallers(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    restricted: ProjectRule.RestrictedCallers,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
    out: *std.ArrayList(Violation),
) !void {
    var callee_types: std.StringHashMapUnmanaged(void) = .empty;
    defer callee_types.deinit(allocator);

    var defs = index.fileIterator();
    while (defs.next()) |file| {
        for (file.classes) |class_def| {
            if (!std.mem.endsWith(u8, class_def.name, restricted.callee_suffix)) continue;
            try callee_types.put(allocator, class_def.name, {});
        }
    }

    if (path_filter) |path| {
        const file = index.get(path) orelse return;

        try restrictedCallsInFile(allocator, rule_id, restricted, file, &callee_types, out);

        return;
    }

    var callers = index.fileIterator();
    while (callers.next()) |file| {
        try restrictedCallsInFile(allocator, rule_id, restricted, file, &callee_types, out);
    }
}

fn restrictedCallsInFile(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    restricted: ProjectRule.RestrictedCallers,
    file: *const facts.FileFacts,
    callee_types: *const std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(Violation),
) !void {
    for (file.calls) |call| {
        if (call.receiver.len == 0) continue;
        const receiver_type = facts.receiverType(file, call.receiver) orelse continue;
        if (!std.mem.endsWith(u8, receiver_type, restricted.callee_suffix)) continue;
        if (!callee_types.contains(receiver_type)) continue;
        if (call.container.len > 0 and std.mem.endsWith(u8, call.container, restricted.caller_suffix)) continue;

        try out.append(allocator, .{
            .path = file.path,
            .diagnostic = .{
                .rule_id = rule_id,
                .language = file.lang.toString(),
                .rule_scope = .project,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "call to {s}.{s} is restricted to *{s} callers",
                    .{ receiver_type, call.method, restricted.caller_suffix },
                ),
                .range = call.range,
            },
        });
    }
}

fn evaluateImportBoundary(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    boundary: ProjectRule.ImportBoundary,
    index: *const ProjectIndex,
    path_filter: ?[]const u8,
    out: *std.ArrayList(Violation),
) !void {
    if (path_filter) |path| {
        const file = index.get(path) orelse return;
        try importBoundaryInFile(allocator, rule_id, boundary, file, out);

        return;
    }

    var files = index.fileIterator();
    while (files.next()) |file| {
        try importBoundaryInFile(allocator, rule_id, boundary, file, out);
    }
}

fn importBoundaryInFile(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    boundary: ProjectRule.ImportBoundary,
    file: *const facts.FileFacts,
    out: *std.ArrayList(Violation),
) !void {
    if (!glob.match(boundary.from, file.path)) return;
    for (file.imports) |im| {
        if (!try importDenied(allocator, boundary.deny, file.path, file.lang, im.source)) continue;

        try out.append(allocator, .{
            .path = file.path,
            .diagnostic = .{
                .rule_id = rule_id,
                .language = file.lang.toString(),
                .rule_scope = .project,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "import \"{s}\" is denied from {s}",
                    .{ im.source, boundary.from },
                ),
                .range = im.range,
            },
        });
    }
}

fn importDenied(
    allocator: std.mem.Allocator,
    deny: []const u8,
    importer_path: []const u8,
    lang: language.Name,
    specifier: []const u8,
) !bool {
    const resolved = (try facts.resolveImportSource(allocator, lang.family(), importer_path, specifier)) orelse return false;

    return glob.match(deny, resolved);
}

pub fn violationLessThan(_: void, a: Violation, b: Violation) bool {
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }

    return diagnostic.lessThan({}, a.diagnostic, b.diagnostic);
}

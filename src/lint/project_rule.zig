const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const ScopedId = rule.ScopedId;

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

pub fn evaluate(
    allocator: std.mem.Allocator,
    rules: []const ProjectRule,
    warnings: []const ScopedId,
    index: *const ProjectIndex,
) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(allocator);

    for (rules) |project| {
        switch (project.kind) {
            .restricted_callers => |rc| try evaluateRestrictedCallers(allocator, project.id, rc, index, &out),
            .import_boundary => |ib| try evaluateImportBoundary(allocator, project.id, ib, index, &out),
        }
    }

    for (out.items) |*v| {
        if (matchesWarning(warnings, v.diagnostic.language, v.diagnostic.rule_id)) v.diagnostic.severity = .warn;
    }

    std.mem.sort(Violation, out.items, {}, violationLessThan);
    return out.toOwnedSlice(allocator);
}

fn matchesWarning(warnings: []const ScopedId, lang_str: []const u8, id: []const u8) bool {
    const lang = language.Name.fromString(lang_str) orelse return false;
    for (warnings) |w| {
        if (w.matches(lang, id)) return true;
    }
    return false;
}

fn evaluateRestrictedCallers(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    restricted: ProjectRule.RestrictedCallers,
    index: *const ProjectIndex,
    out: *std.ArrayList(Violation),
) !void {
    var callee_types: std.StringHashMapUnmanaged(void) = .empty;
    defer callee_types.deinit(allocator);

    var defs = index.files.valueIterator();
    while (defs.next()) |file| {
        for (file.classes) |class_def| {
            if (!std.mem.endsWith(u8, class_def.name, restricted.callee_suffix)) continue;
            try callee_types.put(allocator, class_def.name, {});
        }
    }

    var callers = index.files.valueIterator();
    while (callers.next()) |file| {
        for (file.calls) |call| {
            if (call.receiver.len == 0) continue;
            const receiver_type = receiverType(file, call.receiver) orelse continue;
            if (!std.mem.endsWith(u8, receiver_type, restricted.callee_suffix)) continue;
            if (!callee_types.contains(receiver_type)) continue;
            if (call.container.len > 0 and std.mem.endsWith(u8, call.container, restricted.caller_suffix)) continue;

            try out.append(allocator, .{
                .path = file.path,
                .diagnostic = .{
                    .rule_id = rule_id,
                    .language = file.lang.toString(),
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
}

fn evaluateImportBoundary(
    allocator: std.mem.Allocator,
    rule_id: []const u8,
    boundary: ProjectRule.ImportBoundary,
    index: *const ProjectIndex,
    out: *std.ArrayList(Violation),
) !void {
    var files = index.files.valueIterator();
    while (files.next()) |file| {
        if (!glob.match(boundary.from, file.path)) continue;
        for (file.imports) |im| {
            if (!try importDenied(allocator, boundary.deny, file.path, file.lang, im.source)) continue;
            try out.append(allocator, .{
                .path = file.path,
                .diagnostic = .{
                    .rule_id = rule_id,
                    .language = file.lang.toString(),
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
}

fn importDenied(
    allocator: std.mem.Allocator,
    deny: []const u8,
    importer_path: []const u8,
    lang: language.Name,
    specifier: []const u8,
) !bool {
    if (lang == .go or !isRelativeSpecifier(specifier)) return glob.match(deny, specifier);
    const resolved = try resolveRelative(allocator, importer_path, specifier) orelse return false;
    return glob.match(deny, resolved);
}

fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

fn resolveRelative(
    allocator: std.mem.Allocator,
    importer_path: []const u8,
    specifier: []const u8,
) !?[]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    const dir = std.fs.path.dirname(importer_path) orelse "";
    var dir_it = std.mem.tokenizeScalar(u8, dir, '/');
    while (dir_it.next()) |segment| try segments.append(allocator, segment);

    var spec_it = std.mem.tokenizeScalar(u8, specifier, '/');
    while (spec_it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.pop() == null) return null;
            continue;
        }
        try segments.append(allocator, segment);
    }
    return try std.mem.join(allocator, "/", segments.items);
}

fn receiverType(file: *const facts.FileFacts, receiver: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (file.typed_decls) |decl| {
        if (!std.mem.eql(u8, decl.name, receiver)) continue;
        if (found) |existing| {
            if (!std.mem.eql(u8, existing, decl.type_name)) return null;
        } else {
            found = decl.type_name;
        }
    }
    return found;
}

fn violationLessThan(_: void, a: Violation, b: Violation) bool {
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.diagnostic.range.start.line != b.diagnostic.range.start.line)
        return a.diagnostic.range.start.line < b.diagnostic.range.start.line;
    if (a.diagnostic.range.start.column != b.diagnostic.range.start.column)
        return a.diagnostic.range.start.column < b.diagnostic.range.start.column;
    return std.mem.order(u8, a.diagnostic.rule_id, b.diagnostic.rule_id) == .lt;
}

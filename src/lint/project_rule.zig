const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");
const glob = @import("glob.zig");
const language = @import("language.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const ProjectRule = struct {
    id: []const u8,
    kind: Kind,
    callee_suffix: []const u8 = "",
    caller_suffix: []const u8 = "",
    from: []const u8 = "",
    deny: []const u8 = "",

    pub const Kind = enum {
        restricted_callers,
        import_boundary,

        pub fn fromString(s: []const u8) ?Kind {
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
    index: *const ProjectIndex,
) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(allocator);

    for (rules) |rule| {
        switch (rule.kind) {
            .restricted_callers => try evaluateRestrictedCallers(allocator, rule, index, &out),
            .import_boundary => try evaluateImportBoundary(allocator, rule, index, &out),
        }
    }

    std.mem.sort(Violation, out.items, {}, violationLessThan);
    return out.toOwnedSlice(allocator);
}

fn evaluateRestrictedCallers(
    allocator: std.mem.Allocator,
    rule: ProjectRule,
    index: *const ProjectIndex,
    out: *std.ArrayList(Violation),
) !void {
    var callee_types: std.StringHashMapUnmanaged(void) = .empty;
    defer callee_types.deinit(allocator);

    var defs = index.files.valueIterator();
    while (defs.next()) |file| {
        for (file.classes) |class_def| {
            if (!std.mem.endsWith(u8, class_def.name, rule.callee_suffix)) continue;
            try callee_types.put(allocator, class_def.name, {});
        }
    }

    var callers = index.files.valueIterator();
    while (callers.next()) |file| {
        for (file.calls) |call| {
            if (call.receiver.len == 0) continue;
            const receiver_type = receiverType(file, call.receiver) orelse continue;
            if (!std.mem.endsWith(u8, receiver_type, rule.callee_suffix)) continue;
            if (!callee_types.contains(receiver_type)) continue;
            if (call.container.len > 0 and std.mem.endsWith(u8, call.container, rule.caller_suffix)) continue;

            try out.append(allocator, .{
                .path = file.path,
                .diagnostic = .{
                    .rule_id = rule.id,
                    .language = file.lang.toString(),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "call to {s}.{s} is restricted to *{s} callers",
                        .{ receiver_type, call.method, rule.caller_suffix },
                    ),
                    .range = call.range,
                },
            });
        }
    }
}

fn evaluateImportBoundary(
    allocator: std.mem.Allocator,
    rule: ProjectRule,
    index: *const ProjectIndex,
    out: *std.ArrayList(Violation),
) !void {
    var files = index.files.valueIterator();
    while (files.next()) |file| {
        if (!glob.match(rule.from, file.path)) continue;
        for (file.imports) |im| {
            if (!try importDenied(allocator, rule.deny, file.path, file.lang, im.source)) continue;
            try out.append(allocator, .{
                .path = file.path,
                .diagnostic = .{
                    .rule_id = rule.id,
                    .language = file.lang.toString(),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "import \"{s}\" is denied from {s}",
                        .{ im.source, rule.from },
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
    if (glob.match(deny, specifier)) return true;
    if (lang == .go or !isRelativeSpecifier(specifier)) return false;
    const resolved = try resolveRelative(allocator, importer_path, specifier);
    return glob.match(deny, resolved);
}

fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

fn resolveRelative(
    allocator: std.mem.Allocator,
    importer_path: []const u8,
    specifier: []const u8,
) ![]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    const dir = std.fs.path.dirname(importer_path) orelse "";
    var dir_it = std.mem.tokenizeScalar(u8, dir, '/');
    while (dir_it.next()) |segment| try segments.append(allocator, segment);

    var spec_it = std.mem.tokenizeScalar(u8, specifier, '/');
    while (spec_it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, segment);
    }
    return std.mem.join(allocator, "/", segments.items);
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

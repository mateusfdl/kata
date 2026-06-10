const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const facts = @import("facts.zig");

const ProjectIndex = @import("ProjectIndex.zig").ProjectIndex;

pub const ProjectRule = struct {
    id: []const u8,
    kind: Kind,
    callee_suffix: []const u8,
    caller_suffix: []const u8,

    pub const Kind = enum {
        restricted_callers,

        pub fn fromString(s: []const u8) ?Kind {
            if (std.mem.eql(u8, s, "restricted-callers")) return .restricted_callers;
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

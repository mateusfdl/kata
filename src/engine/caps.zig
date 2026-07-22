const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const rule = @import("rule.zig");

const overflow_shown: u32 = 3;

const Group = struct {
    total: u32 = 0,
    shown: u32 = 0,
    first: ?diagnostic.Diagnostic = null,
};

pub fn apply(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
    settings: []const rule.RuleSetting,
    default_cap: u32,
) ![]diagnostic.Diagnostic {
    var groups: std.StringHashMapUnmanaged(Group) = .empty;

    for (diagnostics) |d| {
        const gop = try groups.getOrPut(arena, d.rule_id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .first = d };
        gop.value_ptr.total += 1;
    }

    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;
    for (diagnostics) |d| {
        const group = groups.getPtr(d.rule_id).?;
        const cap = capFor(settings, default_cap, d.rule_id);
        if (cap == 0 or group.total <= cap) {
            try out.append(arena, d);
            continue;
        }

        const show = @min(overflow_shown, group.total);
        if (group.shown >= show) continue;

        group.shown += 1;
        try out.append(arena, d);
        if (group.shown == show) try out.append(arena, try overflowDiagnostic(arena, group.first.?, group.total, show));
    }

    return out.toOwnedSlice(arena);
}

fn capFor(settings: []const rule.RuleSetting, default_cap: u32, rule_id: []const u8) u32 {
    for (settings) |setting| {
        if (!std.mem.eql(u8, setting.id, rule_id)) continue;

        return setting.max_matches orelse default_cap;
    }

    return default_cap;
}

fn overflowDiagnostic(
    arena: std.mem.Allocator,
    first: diagnostic.Diagnostic,
    total: u32,
    shown: u32,
) !diagnostic.Diagnostic {
    return .{
        .rule_id = first.rule_id,
        .language = first.language,
        .message = try std.fmt.allocPrint(
            arena,
            "rule {s} fired {d} times in this file; showing {d}, suppressed {d}; a flood usually means a broken pattern or wrong scope",
            .{ first.rule_id, total, shown, total - shown },
        ),
        .range = first.range,
        .severity = first.severity,
        .maturity = first.maturity,
        .capped = true,
    };
}

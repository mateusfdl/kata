const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const DiagnosticAdapter = @import("group_cap.zig").DiagnosticAdapter;
const rule = @import("rule.zig");
const group_cap = @import("shared").group_cap;

const DiagnosticCap = group_cap.Type(
    diagnostic.Diagnostic,
    DiagnosticAdapter.GroupKey,
    DiagnosticAdapter.GroupContext,
    DiagnosticAdapter,
);

pub fn apply(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
    settings: []const rule.RuleSetting,
    default_cap: u32,
) ![]diagnostic.Diagnostic {
    return DiagnosticCap.apply(arena, diagnostics, .{}, .{
        .settings = settings,
        .default_cap = default_cap,
    }, 3);
}

const collapse_threshold: usize = 3;

pub fn collapse(
    arena: std.mem.Allocator,
    diagnostics: []const diagnostic.Diagnostic,
) ![]diagnostic.Diagnostic {
    var out: std.ArrayList(diagnostic.Diagnostic) = .empty;

    var start: usize = 0;
    while (start < diagnostics.len) {
        var end = start + 1;
        while (end < diagnostics.len and sameLineFinding(diagnostics[start], diagnostics[end])) end += 1;

        const run = end - start;
        if (run > collapse_threshold) {
            var merged = diagnostics[start];
            merged.message = try std.fmt.allocPrint(arena, "{s}; repeated {d} times on this line", .{
                diagnostics[start].message, run,
            });
            try out.append(arena, merged);
        } else {
            try out.appendSlice(arena, diagnostics[start..end]);
        }

        start = end;
    }

    return out.toOwnedSlice(arena);
}

fn sameLineFinding(a: diagnostic.Diagnostic, b: diagnostic.Diagnostic) bool {
    return a.range.start.line == b.range.start.line and
        std.mem.eql(u8, a.rule_id, b.rule_id) and
        std.mem.eql(u8, a.message, b.message);
}

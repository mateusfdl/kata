const std = @import("std");

const diagnostic = @import("diagnostic.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");

pub const DiagnosticAdapter = struct {
    settings: []const rule.RuleSetting,
    default_cap: u32,

    pub const GroupKey = struct {
        // Scope is part of identity because project and language rules can use
        // the same ID but resolve different policies.
        rule_scope: diagnostic.RuleScope,
        language: []const u8,
        rule_id: []const u8,
    };

    pub const GroupContext = struct {
        pub fn hash(_: GroupContext, key_value: GroupKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(@tagName(key_value.rule_scope));
            hasher.update("\x00");
            hasher.update(key_value.language);
            hasher.update("\x00");
            hasher.update(key_value.rule_id);
            return hasher.final();
        }

        pub fn eql(_: GroupContext, a: GroupKey, b: GroupKey) bool {
            return a.rule_scope == b.rule_scope and
                std.mem.eql(u8, a.language, b.language) and
                std.mem.eql(u8, a.rule_id, b.rule_id);
        }
    };

    pub fn key(_: DiagnosticAdapter, item: diagnostic.Diagnostic) GroupKey {
        return .{
            .rule_scope = item.rule_scope,
            // Project rules aggregate facts from all languages and therefore
            // share one cap. Language rule caps are independent per language.
            .language = if (item.rule_scope == .language) item.language else "",
            .rule_id = item.rule_id,
        };
    }

    pub fn cap(self: DiagnosticAdapter, key_value: GroupKey) usize {
        // Rebuild the policy scope from the same identity used for grouping, so
        // an item cannot consume one group and resolve another group's cap.
        const scope: rule.Scope = switch (key_value.rule_scope) {
            .language => .{ .language = language.Name.fromString(key_value.language) orelse return self.default_cap },
            .project => .project,
        };
        return rule.resolvePolicy(self.settings, scope, key_value.rule_id, null).max_matches orelse self.default_cap;
    }

    pub fn overflow(
        _: DiagnosticAdapter,
        arena: std.mem.Allocator,
        first: diagnostic.Diagnostic,
        total: usize,
        shown: usize,
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
            .rule_scope = first.rule_scope,
        };
    }
};

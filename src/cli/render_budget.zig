const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

pub const render_budget_per_rule: usize = 200;

pub const RenderBudget = struct {
    gpa: std.mem.Allocator,
    per_rule: usize = render_budget_per_rule,
    // Keys borrow engine-owned rule IDs that outlive this run. deinit frees only
    // map storage, not the key bytes.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        rendered: usize = 0,
        suppressed: usize = 0,
        files: usize = 0,
    };

    pub fn deinit(self: *RenderBudget) void {
        self.entries.deinit(self.gpa);
    }

    pub fn filter(
        self: *RenderBudget,
        arena: std.mem.Allocator,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) ![]const lint.diagnostic.Diagnostic {
        var kept: std.ArrayList(lint.diagnostic.Diagnostic) = .empty;
        // Aggregate suppression by rule before updating totals so one file batch
        // increments the affected-file count once per rule.
        var suppressed: std.StringHashMapUnmanaged(usize) = .empty;
        var filtering = false;

        for (diagnostics, 0..) |d, i| {
            if (try self.take(d.rule_id)) {
                if (filtering) try kept.append(arena, d);
                continue;
            }

            if (!filtering) {
                filtering = true;
                try kept.appendSlice(arena, diagnostics[0..i]);
            }

            const gop = try suppressed.getOrPut(arena, d.rule_id);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }

        // Avoid allocating a replacement slice unless something was suppressed.
        if (!filtering) return diagnostics;

        var it = suppressed.iterator();
        while (it.next()) |entry| try self.recordSuppressed(entry.key_ptr.*, entry.value_ptr.*);

        return kept.toOwnedSlice(arena);
    }

    fn take(self: *RenderBudget, rule_id: []const u8) !bool {
        const gop = try self.entries.getOrPut(self.gpa, rule_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        if (gop.value_ptr.rendered >= self.per_rule) {
            return false;
        }

        gop.value_ptr.rendered += 1;

        return true;
    }

    fn recordSuppressed(self: *RenderBudget, rule_id: []const u8, count: usize) !void {
        const gop = try self.entries.getOrPut(self.gpa, rule_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        gop.value_ptr.suppressed += count;
        gop.value_ptr.files += 1;
    }

    pub fn overflow(self: *RenderBudget, arena: std.mem.Allocator) ![]const reports.RuleOverflow {
        // The slice belongs to arena. Rule IDs still borrow engine-owned keys and
        // remain valid through reporter.finish.
        var out: std.ArrayList(reports.RuleOverflow) = .empty;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.suppressed == 0) continue;

            try out.append(arena, .{
                .rule_id = entry.key_ptr.*,
                .suppressed = entry.value_ptr.suppressed,
                .files = entry.value_ptr.files,
            });
        }

        const items = try out.toOwnedSlice(arena);
        std.mem.sort(reports.RuleOverflow, items, {}, lessByRuleId);

        return items;
    }

    fn lessByRuleId(_: void, a: reports.RuleOverflow, b: reports.RuleOverflow) bool {
        return std.mem.order(u8, a.rule_id, b.rule_id) == .lt;
    }
};

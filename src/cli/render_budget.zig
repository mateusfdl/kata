const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

const Diagnostic = lint.diagnostic.Diagnostic;

pub const per_rule: usize = 200;

/// Limits how many diagnostics of one rule a complete run renders. What goes
/// over the limit is counted per rule and reported as overflow.
pub const RenderBudget = struct {
    gpa: std.mem.Allocator,
    // Keys borrow engine-owned rule IDs that outlive this run. deinit frees only
    // map storage, not the key bytes.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        rendered: usize = 0,
        suppressed: usize = 0,
        files: std.StringHashMapUnmanaged(void) = .empty,
    };

    pub fn deinit(self: *RenderBudget) void {
        var entries = self.entries.valueIterator();
        while (entries.next()) |entry| {
            var paths = entry.files.keyIterator();
            while (paths.next()) |path| self.gpa.free(path.*);
            entry.files.deinit(self.gpa);
        }
        self.entries.deinit(self.gpa);
    }

    /// Paths are copied only when suppressed, so callers may reuse their path buffers.
    pub fn filterFile(self: *RenderBudget, arena: std.mem.Allocator, path: []const u8, diagnostics: []const Diagnostic) ![]const Diagnostic {
        var kept: std.ArrayList(Diagnostic) = try .initCapacity(arena, diagnostics.len);
        for (diagnostics) |d| {
            const gop = try self.entries.getOrPut(self.gpa, d.rule_id);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const entry = gop.value_ptr;

            if (entry.rendered < per_rule) {
                entry.rendered += 1;
                kept.appendAssumeCapacity(d);

                continue;
            }

            entry.suppressed += 1;
            if (!entry.files.contains(path)) {
                const owned_path = try self.gpa.dupe(u8, path);
                errdefer self.gpa.free(owned_path);
                try entry.files.put(self.gpa, owned_path, {});
            }
        }

        return kept.items;
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
                .files = entry.value_ptr.files.count(),
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

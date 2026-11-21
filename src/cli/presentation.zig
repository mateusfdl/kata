const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

const PerRuleOutputLimit = @import("per_rule_output_limit.zig").PerRuleOutputLimit;
const FileDiagnostics = @import("file_diagnostics.zig").FileDiagnostics;

const Diagnostic = lint.diagnostic.Diagnostic;
const Violation = lint.project_rule.Violation;

/// What a check shows and what it counts. The caps, the collapse and the
/// per-rule output limit change what is printed. They never change the totals, so the
/// exit code does not depend on them.
pub const Presentation = struct {
    reporter: *reports.Reporter,
    settings: []const lint.rule.RuleSetting,
    max_matches: u32,
    // One limit covers the complete run. Files consume it in walk order;
    // project violations consume what remains after indexing finishes.
    output_limit: PerRuleOutputLimit,
    counts: reports.Counts = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        reporter: *reports.Reporter,
        settings: []const lint.rule.RuleSetting,
        max_matches: u32,
    ) Presentation {
        return .{
            .reporter = reporter,
            .settings = settings,
            .max_matches = max_matches,
            .output_limit = .{ .gpa = gpa },
        };
    }

    pub fn deinit(self: *Presentation) void {
        self.output_limit.deinit();
    }

    pub fn file(
        self: *Presentation,
        arena: std.mem.Allocator,
        result: FileDiagnostics,
    ) !void {
        self.counts.files += 1;
        self.count(result.diagnostics);

        const capped = try lint.caps.apply(arena, result.diagnostics, self.settings, self.max_matches);
        const collapsed = try lint.caps.collapse(arena, capped);

        try self.reporter.file(result.path, result.source, try self.output_limit.filterFile(arena, result.path, collapsed));
    }

    fn project(self: *Presentation, arena: std.mem.Allocator, files: []const ProjectFile) !void {
        var shown: std.ArrayList(Violation) = .empty;

        for (files) |project_file| {
            self.count(project_file.diagnostics);

            const capped = try lint.caps.apply(arena, project_file.diagnostics, self.settings, self.max_matches);
            for (try self.output_limit.filterFile(arena, project_file.path, capped)) |d| {
                try shown.append(arena, .{ .path = project_file.path, .diagnostic = d });
            }
        }

        try self.reporter.project(shown.items);
    }

    /// Call once, after the last file. Project violations are known only when
    /// every file is indexed. Returns true when the run found a violation that
    /// has error severity.
    pub fn finish(self: *Presentation, arena: std.mem.Allocator, project_files: []const ProjectFile) !bool {
        try self.project(arena, project_files);
        try self.reporter.finish(self.counts, try self.output_limit.overflow(arena));

        return self.counts.violations > 0;
    }

    fn count(self: *Presentation, diagnostics: []const Diagnostic) void {
        for (diagnostics) |d| {
            switch (d.severity) {
                .@"error" => self.counts.violations += 1,
                .warn => self.counts.warnings += 1,
            }
        }
    }
};

/// The violations that project rules found in one file.
pub const ProjectFile = struct {
    path: []const u8,
    diagnostics: []const Diagnostic,
};

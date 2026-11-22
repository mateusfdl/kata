const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

const PerRuleOutputLimit = @import("per_rule_output_limit.zig").PerRuleOutputLimit;
const FileDiagnostics = @import("file_diagnostics.zig").FileDiagnostics;

const Diagnostic = lint.diagnostic.Diagnostic;
const Violation = lint.project_rule.Violation;

/// what a check shows and what it counts. the caps, the collapse and the
/// per-rule output limit change what is printed. they never change the totals, so the
/// exit code does not depend on them.
pub const CheckReport = struct {
    reporter: *reports.Reporter,
    settings: []const lint.rule.RuleSetting,
    max_matches: u32,
    // one limit covers the complete run. files consume it in walk order;
    // project violations consume what remains after indexing finishes.
    output_limit: PerRuleOutputLimit,
    counts: reports.Counts = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        reporter: *reports.Reporter,
        settings: []const lint.rule.RuleSetting,
        max_matches: u32,
    ) CheckReport {
        return .{
            .reporter = reporter,
            .settings = settings,
            .max_matches = max_matches,
            .output_limit = .{ .gpa = gpa },
        };
    }

    pub fn deinit(self: *CheckReport) void {
        self.output_limit.deinit();
    }

    pub fn file(
        self: *CheckReport,
        arena: std.mem.Allocator,
        result: FileDiagnostics,
    ) !void {
        self.counts.files += 1;
        self.count(result.diagnostics);

        const capped = try lint.caps.apply(arena, result.diagnostics, self.settings, self.max_matches);
        const collapsed = try lint.caps.collapse(arena, capped);

        try self.reporter.file(result.path, result.source, try self.output_limit.filterFile(arena, result.path, collapsed));
    }

    fn project(self: *CheckReport, arena: std.mem.Allocator, files: []const ProjectFileViolations) !void {
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

    /// call once, after the last file. project violations are known only when
    /// every file is indexed. returns true when the run found a violation that
    /// has error severity.
    pub fn finish(self: *CheckReport, arena: std.mem.Allocator, project_files: []const ProjectFileViolations) !bool {
        try self.project(arena, project_files);
        try self.reporter.finish(self.counts, try self.output_limit.overflow(arena));

        return self.counts.violations > 0;
    }

    fn count(self: *CheckReport, diagnostics: []const Diagnostic) void {
        for (diagnostics) |d| {
            switch (d.severity) {
                .@"error" => self.counts.violations += 1,
                .warn => self.counts.warnings += 1,
            }
        }
    }
};

/// the violations that project rules found in one file.
pub const ProjectFileViolations = struct {
    path: []const u8,
    diagnostics: []const Diagnostic,
};

const std = @import("std");

const lint = @import("engine");
const summary = @import("summary.zig");

const Counts = summary.Counts;
const RuleOverflow = summary.RuleOverflow;

pub const Report = struct {
    writer: *std.Io.Writer,

    pub fn file(
        self: *Report,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        _ = source;

        for (diagnostics) |d| try self.printDiagnostic(path, d);
    }

    pub fn project(self: *Report, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        for (violations) |v| try self.printDiagnostic(v.path, v.diagnostic);
    }

    pub fn finish(
        self: *Report,
        counts: Counts,
        overflow: []const RuleOverflow,
    ) std.Io.Writer.Error!void {
        for (overflow) |o| {
            try self.writer.print("rule {s}: and {d} more in {d} files\n", .{
                o.rule_id,
                o.suppressed,
                o.files,
            });
        }

        try self.writer.print("checked {d} files, {d} violations, {d} warnings\n", .{
            counts.files,
            counts.violations,
            counts.warnings,
        });

        try self.writer.flush();
    }

    fn printDiagnostic(self: *Report, path: []const u8, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        const marker: []const u8 = switch (d.severity) {
            .@"error" => "",
            .warn => "warn ",
        };

        try self.writer.print("{s}:{d}:{d} {s}[{s}] {s}\n", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            marker,
            d.rule_id,
            d.message,
        });
    }
};

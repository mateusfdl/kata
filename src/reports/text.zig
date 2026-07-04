const std = @import("std");

const lint = @import("../lint.zig");
const reports = @import("../reports.zig");

pub const Text = struct {
    writer: *std.Io.Writer,

    pub fn file(
        self: *Text,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        _ = source;
        for (diagnostics) |d| try self.printDiagnostic(path, d);
    }

    pub fn project(self: *Text, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        for (violations) |v| try self.printDiagnostic(v.path, v.diagnostic);
    }

    pub fn finish(self: *Text, counts: reports.Counts) std.Io.Writer.Error!void {
        try self.writer.print("checked {d} files, {d} violations, {d} warnings\n", .{
            counts.files,
            counts.violations,
            counts.warnings,
        });

        try self.writer.flush();
    }

    fn printDiagnostic(self: *Text, path: []const u8, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
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

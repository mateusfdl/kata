const std = @import("std");

const lint = @import("engine");
const summary = @import("summary.zig");

const Counts = summary.Counts;
const RuleOverflow = summary.RuleOverflow;

pub const Report = struct {
    // File entries stream into one open document. finish also closes clean runs
    // where no file call started the object.
    stringify: std.json.Stringify,
    started: bool = false,

    pub fn init(writer: *std.Io.Writer) Report {
        return .{ .stringify = .{ .writer = writer } };
    }

    pub fn file(
        self: *Report,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        _ = source;

        if (diagnostics.len == 0) return;

        try self.entry(path, diagnostics);
    }

    pub fn project(self: *Report, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        for (violations) |violation| try self.entry(violation.path, &.{violation.diagnostic});
    }

    pub fn finish(
        self: *Report,
        counts: Counts,
        overflow: []const RuleOverflow,
    ) std.Io.Writer.Error!void {
        try self.begin();
        try self.stringify.endArray();
        try self.stringify.objectField("summary");
        try self.stringify.write(.{
            .files = counts.files,
            .violations = counts.violations,
            .warnings = counts.warnings,
            .capped_rules = overflow,
        });
        try self.stringify.endObject();
        try self.stringify.writer.writeByte('\n');
        try self.stringify.writer.flush();
    }

    fn begin(self: *Report) std.Io.Writer.Error!void {
        if (self.started) return;

        self.started = true;

        try self.stringify.beginObject();
        try self.stringify.objectField("files");
        try self.stringify.beginArray();
    }

    fn entry(self: *Report, path: []const u8, diagnostics: []const lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        try self.begin();
        try self.stringify.write(.{
            .path = path,
            .diagnostics = diagnostics,
        });
    }
};

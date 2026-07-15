const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");

pub const Json = struct {
    writer: *std.Io.Writer,
    started: bool = false,
    wrote_entry: bool = false,

    pub fn file(
        self: *Json,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        _ = source;
        if (diagnostics.len == 0) return;
        try self.entry(path, diagnostics);
    }

    pub fn project(self: *Json, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        for (violations) |v| try self.entry(v.path, &.{v.diagnostic});
    }

    pub fn finish(self: *Json, counts: reports.Counts) std.Io.Writer.Error!void {
        try self.begin();
        try self.writer.print("],\"summary\":{{\"files\":{d},\"violations\":{d},\"warnings\":{d}}}}}\n", .{
            counts.files,
            counts.violations,
            counts.warnings,
        });

        try self.writer.flush();
    }

    fn begin(self: *Json) std.Io.Writer.Error!void {
        if (self.started) return;

        self.started = true;

        try self.writer.writeAll("{\"files\":[");
    }

    fn entry(self: *Json, path: []const u8, diagnostics: []const lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        try self.begin();

        if (self.wrote_entry) try self.writer.writeAll(",");

        self.wrote_entry = true;

        try self.writer.writeAll("{\"path\":");

        try std.json.Stringify.value(path, .{}, self.writer);
        try self.writer.writeAll(",\"diagnostics\":");

        try std.json.Stringify.value(diagnostics, .{}, self.writer);
        try self.writer.writeAll("}");
    }
};

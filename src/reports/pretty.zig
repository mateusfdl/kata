const std = @import("std");

const lint = @import("../lint.zig");
const reports = @import("../reports.zig");
const text = @import("text.zig");

const utils = @import("utils.zig");

const context_lines = 2;
const reset = "\x1b[0m";

pub const Pretty = struct {
    writer: *std.Io.Writer,
    color: bool = false,

    pub fn file(
        self: *Pretty,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        for (diagnostics) |d| try self.frame(path, source, d);
    }

    pub fn project(self: *Pretty, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        var fallback = text.Text{ .writer = self.writer };

        try fallback.project(violations);
    }

    pub fn finish(self: *Pretty, counts: reports.Counts) std.Io.Writer.Error!void {
        var fallback = text.Text{ .writer = self.writer };

        try fallback.finish(counts);
    }

    fn frame(self: *Pretty, path: []const u8, source: []const u8, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        try self.writer.print("{s}:{d}:{d} [{s}]\n\n", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.rule_id,
        });

        const marker: u8 = switch (d.severity) {
            .@"error" => 'x',
            .warn => '!',
        };
        try self.writer.writeAll("  ");
        try self.paint(d.severity);
        try self.writer.print("{c} {s}", .{ marker, d.message });
        try self.unpaint();
        try self.writer.writeAll("\n\n");

        const target: usize = d.range.start.line;
        const first = target -| context_lines;
        var window: [2 * context_lines + 1][]const u8 = undefined;
        var count: usize = 0;
        var idx: usize = 0;
        var iter = std.mem.splitScalar(u8, utils.trimTrailingNewline(source), '\n');
        while (iter.next()) |line| : (idx += 1) {
            if (idx > target + context_lines) break;
            if (idx < first) continue;
            window[count] = line;
            count += 1;
        }
        if (count == 0) return;

        const width = utils.digits(first + count);
        for (window[0..count], 0..) |line, i| {
            const line_idx = first + i;
            if (line_idx == target) {
                try self.paint(d.severity);
                try self.writer.writeAll(">");
                try self.unpaint();
                try self.writer.writeAll(" ");
                try self.gutterNum(line_idx + 1, width);
                try self.writer.print(" | {s}\n", .{line});
                try self.caretLine(line, d, width);
            } else {
                try self.writer.writeAll("  ");
                try self.gutterNum(line_idx + 1, width);
                try self.writer.print(" | {s}\n", .{line});
            }
        }
        try self.writer.writeAll("\n");
    }

    fn caretLine(self: *Pretty, line: []const u8, d: lint.diagnostic.Diagnostic, width: usize) std.Io.Writer.Error!void {
        const start = @min(d.range.start.column, line.len);
        const span_end = if (d.range.end.line == d.range.start.line) @min(d.range.end.column, line.len) else line.len;
        const carets = @max(span_end -| start, 1);

        try self.repeat(' ', width + 2);
        try self.writer.writeAll(" | ");
        try self.repeat(' ', start);
        try self.paint(d.severity);
        try self.repeat('^', carets);
        try self.unpaint();
        try self.writer.writeAll("\n");
    }

    fn gutterNum(self: *Pretty, display: usize, width: usize) std.Io.Writer.Error!void {
        var buf: [20]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "{d}", .{display}) catch unreachable;
        try self.repeat(' ', width - rendered.len);
        try self.writer.writeAll(rendered);
    }

    fn paint(self: *Pretty, severity: lint.diagnostic.Severity) std.Io.Writer.Error!void {
        if (!self.color) return;
        try self.writer.writeAll(switch (severity) {
            .@"error" => "\x1b[31m",
            .warn => "\x1b[33m",
        });
    }

    fn unpaint(self: *Pretty) std.Io.Writer.Error!void {
        if (!self.color) return;
        try self.writer.writeAll(reset);
    }

    fn repeat(self: *Pretty, byte: u8, n: usize) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writer.writeByte(byte);
    }
};

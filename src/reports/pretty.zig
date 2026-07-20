const std = @import("std");

const lint = @import("engine");
const reports = @import("../reports.zig");
const text = @import("text.zig");

const utils = @import("utils.zig");

const context_lines = 2;
const tab_width = 4;
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
        if (diagnostics.len > 0) try self.writer.flush();
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
        try self.writer.print("{s}:{d}:{d} [{s}]", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.rule_id,
        });
        try self.enclosingContext(d.context);
        try self.writer.writeAll("\n\n");

        const marker: u8 = switch (d.severity) {
            .@"error" => 'x',
            .warn => '!',
        };

        try self.writer.writeAll("  ");
        try self.paint(d.severity);
        try self.writer.print("{c} {s}", .{ marker, d.message });
        try self.unpaint();
        try self.writer.writeAll("\n");
        try self.fixLines(d);
        try self.writer.writeAll("\n");

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
                try self.writer.writeAll(" | ");
                try self.sourceLine(line);
                try self.writer.writeAll("\n");
                try self.caretLine(line, d, width);
            } else {
                try self.writer.writeAll("  ");
                try self.gutterNum(line_idx + 1, width);
                try self.writer.writeAll(" | ");
                try self.sourceLine(line);
                try self.writer.writeAll("\n");
            }
        }

        try self.writer.writeAll("\n");
    }

    fn fixLines(self: *Pretty, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        if (d.fix) |fix| {
            if (self.color) try self.writer.writeAll("\x1b[2m");
            try self.writer.print("  fix: {s}", .{replacementText(fix.replacement)});
            if (fix.safety == .unsafe) try self.writer.writeAll(" (unsafe)");
            if (self.color) try self.writer.writeAll(reset);
            try self.writer.writeAll("\n");
        }

        for (d.suggestions) |suggestion| {
            if (self.color) try self.writer.writeAll("\x1b[2m");
            try self.writer.print("  suggest {s}: {s}", .{ suggestion.label, replacementText(suggestion.replacement) });
            if (self.color) try self.writer.writeAll(reset);
            try self.writer.writeAll("\n");
        }
    }

    fn enclosingContext(self: *Pretty, context: []const lint.diagnostic.Context) std.Io.Writer.Error!void {
        if (context.len == 0) return;

        if (self.color) try self.writer.writeAll("\x1b[2m");

        var index = context.len;
        const first = context.len -| 2;
        while (index > first) {
            index -= 1;
            const entry = context[index];
            if (index == context.len - 1) {
                try self.writer.print(" in {s} {s}", .{ @tagName(entry.kind), entry.name });
            } else {
                try self.writer.print(" of {s} {s}", .{ @tagName(entry.kind), entry.name });
            }
        }

        if (self.color) try self.writer.writeAll(reset);
    }

    fn caretLine(self: *Pretty, line: []const u8, d: lint.diagnostic.Diagnostic, width: usize) std.Io.Writer.Error!void {
        const start_byte = @min(d.range.start.column, line.len);
        const end_byte = if (d.range.end.line == d.range.start.line) @min(d.range.end.column, line.len) else line.len;
        const start = renderedWidth(line[0..start_byte]);
        const span_end = renderedWidth(line[0..end_byte]);
        const carets = @max(span_end -| start, 1);

        try self.repeat(' ', width + 2);
        try self.writer.writeAll(" | ");
        try self.repeat(' ', start);
        try self.paint(d.severity);
        try self.repeat('^', carets);
        try self.unpaint();
        try self.writer.writeAll("\n");
    }

    fn sourceLine(self: *Pretty, line: []const u8) std.Io.Writer.Error!void {
        var col: usize = 0;
        for (line) |c| {
            if (c == '\t') {
                const pad = tab_width - (col % tab_width);
                try self.repeat(' ', pad);

                col += pad;
            } else {
                try self.writer.writeByte(c);

                col += 1;
            }
        }
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

fn replacementText(replacement: []const u8) []const u8 {
    return if (replacement.len == 0) "remove" else replacement;
}

fn renderedWidth(prefix: []const u8) usize {
    var col: usize = 0;

    for (prefix) |c| {
        col += if (c == '\t') tab_width - (col % tab_width) else 1;
    }

    return col;
}

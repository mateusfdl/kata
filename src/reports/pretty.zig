const std = @import("std");

const lint = @import("engine");
const summary = @import("summary.zig");
const text = @import("text.zig");

const Counts = summary.Counts;
const RuleOverflow = summary.RuleOverflow;

const context_lines = 2;
const tab_width = 4;
const dim = "\x1b[2m";
const gutter_separator = " | ";
const reset = "\x1b[0m";

pub const Report = struct {
    writer: *std.Io.Writer,
    color: bool = false,

    pub fn file(
        self: *Report,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) std.Io.Writer.Error!void {
        for (diagnostics) |d| try self.frame(path, source, d);

        // A pretty file report is complete on its own. Flush it so long checks
        // show findings while later files are still running.
        if (diagnostics.len > 0) try self.writer.flush();
    }

    pub fn project(self: *Report, violations: []const lint.project_rule.Violation) std.Io.Writer.Error!void {
        var fallback = text.Report{ .writer = self.writer };

        try fallback.project(violations);
    }

    pub fn finish(
        self: *Report,
        counts: Counts,
        overflow: []const RuleOverflow,
    ) std.Io.Writer.Error!void {
        var fallback = text.Report{ .writer = self.writer };

        try fallback.finish(counts, overflow);
    }

    fn frame(self: *Report, path: []const u8, source: []const u8, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
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
        try self.resetColor();
        try self.writer.writeAll("\n");
        try self.fixLines(d);
        try self.writer.writeAll("\n");

        const target: usize = d.range.start.line;
        const first = target -| context_lines;
        var window: [2 * context_lines + 1][]const u8 = undefined;
        var count: usize = 0;
        var idx: usize = 0;
        var iter = std.mem.splitScalar(u8, trimTrailingNewline(source), '\n');
        while (iter.next()) |line| : (idx += 1) {
            if (idx > target + context_lines) break;
            if (idx < first) continue;

            window[count] = line;
            count += 1;
        }

        if (count == 0) return;

        const width = digits(first + count);
        for (window[0..count], 0..) |line, i| {
            const line_idx = first + i;

            if (line_idx == target) {
                try self.paint(d.severity);
                try self.writer.writeAll(">");
                try self.resetColor();
                try self.writer.writeAll(" ");
                try self.gutterNum(line_idx + 1, width);
                try self.writer.writeAll(gutter_separator);
                try self.sourceLine(line);
                try self.writer.writeAll("\n");
                try self.caretLine(line, d, width);
            } else {
                try self.writer.writeAll("  ");
                try self.gutterNum(line_idx + 1, width);
                try self.writer.writeAll(gutter_separator);
                try self.sourceLine(line);
                try self.writer.writeAll("\n");
            }
        }

        try self.writer.writeAll("\n");
    }

    fn fixLines(self: *Report, d: lint.diagnostic.Diagnostic) std.Io.Writer.Error!void {
        if (d.fix) |fix| {
            try self.dimColor();
            try self.writer.print("  fix: {s}", .{replacementText(fix.replacement)});
            if (fix.safety == .unsafe) try self.writer.writeAll(" (unsafe)");
            try self.resetColor();
            try self.writer.writeAll("\n");
        }

        for (d.suggestions) |suggestion| {
            try self.dimColor();
            try self.writer.print("  suggest {s}: {s}", .{ suggestion.label, replacementText(suggestion.replacement) });
            try self.resetColor();
            try self.writer.writeAll("\n");
        }
    }

    fn enclosingContext(self: *Report, context: []const lint.diagnostic.Context) std.Io.Writer.Error!void {
        if (context.len == 0) return;

        try self.dimColor();

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

        try self.resetColor();
    }

    fn caretLine(self: *Report, line: []const u8, d: lint.diagnostic.Diagnostic, width: usize) std.Io.Writer.Error!void {
        const start_byte = @min(d.range.start.column, line.len);
        const end_byte = if (d.range.end.line == d.range.start.line) @min(d.range.end.column, line.len) else line.len;
        const start = renderedWidth(line[0..start_byte]);
        const span_end = renderedWidth(line[0..end_byte]);
        const carets = @max(span_end -| start, 1);

        try self.repeat(' ', width + 2);
        try self.writer.writeAll(gutter_separator);
        try self.repeat(' ', start);
        try self.paint(d.severity);
        try self.repeat('^', carets);
        try self.resetColor();
        try self.writer.writeAll("\n");
    }

    fn sourceLine(self: *Report, line: []const u8) std.Io.Writer.Error!void {
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

    fn gutterNum(self: *Report, display: usize, width: usize) std.Io.Writer.Error!void {
        var buf: [20]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "{d}", .{display}) catch unreachable;

        try self.repeat(' ', width - rendered.len);
        try self.writer.writeAll(rendered);
    }

    fn paint(self: *Report, severity: lint.diagnostic.Severity) std.Io.Writer.Error!void {
        if (!self.color) return;

        try self.writer.writeAll(switch (severity) {
            .@"error" => "\x1b[31m",
            .warn => "\x1b[33m",
        });
    }

    fn dimColor(self: *Report) std.Io.Writer.Error!void {
        if (!self.color) return;

        try self.writer.writeAll(dim);
    }

    fn resetColor(self: *Report) std.Io.Writer.Error!void {
        if (!self.color) return;

        try self.writer.writeAll(reset);
    }

    fn repeat(self: *Report, byte: u8, n: usize) std.Io.Writer.Error!void {
        var i: usize = 0;

        while (i < n) : (i += 1) try self.writer.writeByte(byte);
    }
};

fn trimTrailingNewline(source: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, source, "\n")) source[0 .. source.len - 1] else source;
}

fn digits(value: usize) usize {
    var count: usize = 1;
    var remaining = value;

    while (remaining >= 10) : (remaining /= 10) count += 1;

    return count;
}

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

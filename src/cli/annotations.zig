const std = @import("std");

const lint = @import("engine");
const sources = @import("../sources.zig");

const language = lint.language;
const lifecycle = sources.lifecycle;

pub const expect_marker = "// kata-expect:";
pub const expect_fix_marker = "// kata-expect-fix:";

pub const Expectation = struct {
    line: u32,
    rule_id: []const u8,
    matched: bool = false,

    pub fn claim(expectations: []Expectation, line: u32, rule_id: []const u8) bool {
        for (expectations) |*e| {
            if (e.matched or e.line != line) continue;
            if (!std.mem.eql(u8, e.rule_id, rule_id)) continue;

            e.matched = true;

            return true;
        }

        return false;
    }
};

pub const FixExpectation = struct {
    line: u32,
    replacement: []const u8,
    matched: bool = false,

    // Fix annotations do not name a rule. The first fixed diagnostic on the
    // target line claims the next unmatched expectation.
    pub fn claim(expectations: []FixExpectation, line: u32) ?*FixExpectation {
        for (expectations) |*e| {
            if (e.matched or e.line != line) continue;

            e.matched = true;

            return e;
        }

        return null;
    }
};

const Annotation = struct {
    line: u32,
    ids: []const []const u8,
};

const FixAnnotation = struct {
    line: u32,
    replacement: []const u8,
};

pub const Parser = struct {
    table: *const lifecycle.Table,
    stdout: *std.Io.Writer,
    expectations: std.ArrayList(Expectation) = .empty,
    fix_expectations: std.ArrayList(FixExpectation) = .empty,
    annotation_lines: std.ArrayList(u32) = .empty,

    pub fn parse(
        parser: *Parser,
        arena: std.mem.Allocator,
        lang: language.Name,
        source: []const u8,
        path: []const u8,
    ) !usize {
        var annotations: std.ArrayList(Annotation) = .empty;
        var fix_annotations: std.ArrayList(FixAnnotation) = .empty;
        var line_no: u32 = 0;

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| : (line_no += 1) {
            const line = std.mem.trim(u8, raw_line, " \t\r");

            if (std.mem.startsWith(u8, line, expect_fix_marker)) {
                try parser.annotation_lines.append(arena, line_no);
                try fix_annotations.append(arena, .{
                    .line = line_no,
                    .replacement = std.mem.trim(u8, line[expect_fix_marker.len..], " \t"),
                });

                continue;
            }

            if (!std.mem.startsWith(u8, line, expect_marker)) continue;

            try parser.annotation_lines.append(arena, line_no);

            var collected: std.ArrayList([]const u8) = .empty;
            var ids = std.mem.tokenizeAny(u8, line[expect_marker.len..], ", \t");

            while (ids.next()) |id| try collected.append(arena, id);

            try annotations.append(arena, .{ .line = line_no, .ids = try collected.toOwnedSlice(arena) });
        }

        // splitScalar adds an empty item after a trailing newline. That item is
        // not a targetable source line.
        var total = line_no;
        if (source.len > 0 and source[source.len - 1] == '\n') total -= 1;

        var failures: usize = 0;
        for (annotations.items) |annotation| {
            if (annotation.ids.len == 0) {
                try parser.stdout.print("{s}:{d} empty kata-expect annotation\n", .{ path, annotation.line + 1 });

                failures += 1;

                continue;
            }

            const target = parser.targetLine(annotation.line, total) orelse {
                try parser.stdout.print("{s}:{d} dangling kata-expect annotation\n", .{ path, annotation.line + 1 });

                failures += 1;

                continue;
            };

            for (annotation.ids) |id| {
                var rule_id = id;
                switch (parser.table.resolve(lang, id)) {
                    .renamed, .replaced => |canonical| {
                        try parser.stdout.print("{s}:{d} renamed [{s} -> {s}]\n", .{ path, annotation.line + 1, id, canonical });

                        rule_id = canonical;
                    },
                    .live, .removed, .unknown => {},
                }

                try parser.expectations.append(arena, .{ .line = target, .rule_id = rule_id });
            }
        }

        for (fix_annotations.items) |annotation| {
            const target = parser.targetLine(annotation.line, total) orelse {
                try parser.stdout.print("{s}:{d} dangling kata-expect-fix annotation\n", .{ path, annotation.line + 1 });

                failures += 1;

                continue;
            };

            try parser.fix_expectations.append(arena, .{ .line = target, .replacement = annotation.replacement });
        }

        return failures;
    }

    pub fn coversLine(parser: *const Parser, line: u32) bool {
        return std.mem.indexOfScalar(u32, parser.annotation_lines.items, line) != null;
    }

    fn targetLine(parser: *const Parser, line: u32, total: u32) ?u32 {
        var target = line + 1;
        // Adjacent expect and expect-fix lines form one annotation block. Every
        // annotation in the block targets the first source line below it.
        while (parser.coversLine(target)) target += 1;
        if (target >= total) {
            return null;
        } else {
            return target;
        }
    }
};

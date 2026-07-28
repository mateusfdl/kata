const std = @import("std");

const build_options = @import("build_options");
const lint = @import("engine");
const reports = @import("../reports.zig");

const RuleRef = struct {
    id: []const u8,
    level: lint.diagnostic.Severity,
};

pub const Sarif = struct {
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    started: bool = false,
    wrote_result: bool = false,
    rules: std.ArrayList(RuleRef) = .empty,

    pub fn file(
        self: *Sarif,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) reports.Error!void {
        _ = source;
        for (diagnostics) |d| try self.result(path, d);
    }

    pub fn project(self: *Sarif, violations: []const lint.project_rule.Violation) reports.Error!void {
        for (violations) |v| try self.result(v.path, v.diagnostic);
    }

    pub fn finish(
        self: *Sarif,
        counts: reports.Counts,
        overflow: []const reports.RuleOverflow,
    ) reports.Error!void {
        _ = overflow;
        _ = counts;
        try self.begin();
        try self.writer.writeAll("],\"tool\":{\"driver\":{\"name\":\"kata\",\"semanticVersion\":");
        try std.json.Stringify.value(build_options.version, .{}, self.writer);
        try self.writer.writeAll(",\"rules\":[");
        for (self.rules.items, 0..) |rule, i| {
            if (i > 0) try self.writer.writeAll(",");
            try self.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(rule.id, .{}, self.writer);
            try self.writer.print(",\"defaultConfiguration\":{{\"level\":\"{s}\"}}}}", .{levelName(rule.level)});
        }
        try self.writer.writeAll("]}}}]}\n");

        for (self.rules.items) |rule| self.gpa.free(rule.id);
        self.rules.deinit(self.gpa);
        self.rules = .empty;

        try self.writer.flush();
    }

    fn begin(self: *Sarif) std.Io.Writer.Error!void {
        if (self.started) return;

        self.started = true;

        try self.writer.writeAll(
            "{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"results\":[",
        );
    }

    fn result(self: *Sarif, path: []const u8, d: lint.diagnostic.Diagnostic) reports.Error!void {
        try self.begin();

        if (self.wrote_result) try self.writer.writeAll(",");

        self.wrote_result = true;

        const index = try self.ruleIndex(d);
        try self.writer.writeAll("{\"ruleId\":");
        try std.json.Stringify.value(d.rule_id, .{}, self.writer);
        try self.writer.print(",\"ruleIndex\":{d},\"level\":\"{s}\",\"message\":{{\"text\":", .{ index, levelName(d.severity) });
        try std.json.Stringify.value(d.message, .{}, self.writer);
        try self.writer.writeAll("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":");
        try std.json.Stringify.value(path, .{}, self.writer);
        try self.writer.print("}},\"region\":{{\"startLine\":{d},\"startColumn\":{d},\"endLine\":{d},\"endColumn\":{d}}}}}}}]", .{
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.range.end.line + 1,
            d.range.end.column + 1,
        });

        if (d.fingerprint.len > 0) {
            try self.writer.writeAll(",\"partialFingerprints\":{\"kataFingerprint/v1\":");
            try std.json.Stringify.value(d.fingerprint, .{}, self.writer);
            try self.writer.writeAll("}");
        }

        try self.fixes(path, d);
        try self.writer.writeAll("}");
    }

    fn fixes(self: *Sarif, path: []const u8, d: lint.diagnostic.Diagnostic) reports.Error!void {
        const fix = d.fix orelse return;
        if (fix.safety != .safe) return;

        try self.writer.writeAll(",\"fixes\":[{\"artifactChanges\":[{\"artifactLocation\":{\"uri\":");
        try std.json.Stringify.value(path, .{}, self.writer);
        try self.writer.print("}},\"replacements\":[{{\"deletedRegion\":{{\"startLine\":{d},\"startColumn\":{d},\"endLine\":{d},\"endColumn\":{d}}}", .{
            fix.range.start.line + 1,
            fix.range.start.column + 1,
            fix.range.end.line + 1,
            fix.range.end.column + 1,
        });

        if (fix.replacement.len > 0) {
            try self.writer.writeAll(",\"insertedContent\":{\"text\":");
            try std.json.Stringify.value(fix.replacement, .{}, self.writer);
            try self.writer.writeAll("}");
        }

        try self.writer.writeAll("}]}]}]");
    }

    fn ruleIndex(self: *Sarif, d: lint.diagnostic.Diagnostic) std.mem.Allocator.Error!usize {
        for (self.rules.items, 0..) |*rule, i| {
            if (!std.mem.eql(u8, rule.id, d.rule_id)) continue;
            if (d.severity == .@"error") rule.level = .@"error";
            return i;
        }

        const id = try self.gpa.dupe(u8, d.rule_id);
        errdefer self.gpa.free(id);

        try self.rules.append(self.gpa, .{ .id = id, .level = d.severity });
        return self.rules.items.len - 1;
    }

    fn levelName(severity: lint.diagnostic.Severity) []const u8 {
        return switch (severity) {
            .@"error" => "error",
            .warn => "warning",
        };
    }
};

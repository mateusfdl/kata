const std = @import("std");

const build_options = @import("build_options");
const lint = @import("engine");
const summary = @import("summary.zig");

const Counts = summary.Counts;
const RuleOverflow = summary.RuleOverflow;

pub const Report = struct {
    pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;
    const Region = struct {
        startLine: usize,
        startColumn: usize,
        endLine: usize,
        endColumn: usize,
    };

    const InsertedContent = struct {
        text: []const u8,
    };

    const Replacement = struct {
        deletedRegion: Region,
        insertedContent: ?InsertedContent = null,
    };

    stringify: std.json.Stringify,
    gpa: std.mem.Allocator,
    started: bool = false,
    // Results stream first, but SARIF emits descriptors later under tool.driver.
    // Retain first-seen rule order and owned IDs until finish closes the document.
    rules: std.ArrayList(struct {
        id: []const u8,
        defaultConfiguration: struct { level: []const u8 },
    }) = .empty,

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Report {
        return .{
            .stringify = .{
                .writer = writer,
                .options = .{ .emit_null_optional_fields = false },
            },
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Report) void {
        for (self.rules.items) |rule| self.gpa.free(rule.id);

        self.rules.deinit(self.gpa);
        self.rules = .empty;
    }

    pub fn file(
        self: *Report,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) Error!void {
        _ = source;

        for (diagnostics) |diagnostic| try self.writeResult(path, diagnostic);
    }

    pub fn project(self: *Report, violations: []const lint.project_rule.Violation) Error!void {
        for (violations) |violation| try self.writeResult(violation.path, violation.diagnostic);
    }

    pub fn finish(
        self: *Report,
        counts: Counts,
        overflow: []const RuleOverflow,
    ) Error!void {
        _ = overflow;
        _ = counts;

        // Retained rule storage must be released even if final serialization fails.
        // deinit is idempotent, so callers can still defer it unconditionally.
        defer self.deinit();

        try self.begin();
        try self.stringify.endArray();
        try writeField(&self.stringify, "tool", .{ .driver = .{
            .name = "kata",
            .semanticVersion = build_options.version,
            .rules = self.rules.items,
        } });
        try self.stringify.endObject();
        try self.stringify.endArray();
        try self.stringify.endObject();
        try self.stringify.writer.writeByte('\n');
        try self.stringify.writer.flush();
    }

    fn begin(self: *Report) std.Io.Writer.Error!void {
        if (self.started) return;

        self.started = true;

        try self.stringify.beginObject();
        try writeField(&self.stringify, "version", "2.1.0");
        try writeField(&self.stringify, "$schema", "https://json.schemastore.org/sarif-2.1.0.json");
        try self.stringify.objectField("runs");
        try self.stringify.beginArray();
        try self.stringify.beginObject();
        try self.stringify.objectField("results");
        try self.stringify.beginArray();
    }

    fn writeResult(self: *Report, path: []const u8, diagnostic: lint.diagnostic.Diagnostic) Error!void {
        try self.begin();

        const index = try self.ruleIndex(diagnostic);

        try self.stringify.beginObject();
        try writeField(&self.stringify, "ruleId", diagnostic.rule_id);
        try writeField(&self.stringify, "ruleIndex", index);
        try writeField(&self.stringify, "level", levelName(diagnostic.severity));
        try writeField(&self.stringify, "message", .{ .text = diagnostic.message });
        try writeField(&self.stringify, "locations", &.{.{ .physicalLocation = .{
            .artifactLocation = .{ .uri = path },
            .region = region(diagnostic.range),
        } }});

        if (diagnostic.fingerprint.len > 0) {
            try writeField(&self.stringify, "partialFingerprints", .{
                .@"kataFingerprint/v1" = diagnostic.fingerprint,
            });
        }

        try self.writeFixes(path, diagnostic.fix);
        try self.stringify.endObject();
    }

    fn writeFixes(self: *Report, path: []const u8, maybe_fix: ?lint.diagnostic.Fix) std.Io.Writer.Error!void {
        const fix = maybe_fix orelse return;

        // SARIF consumers can apply fixes automatically. Emit only declared-safe
        // fixes; unsafe fixes and suggestions remain diagnostic-only.
        if (fix.safety != .safe) return;

        var replacement = Replacement{ .deletedRegion = region(fix.range) };
        // No insertedContent field represents a pure deletion.
        if (fix.replacement.len > 0) replacement.insertedContent = .{ .text = fix.replacement };

        try writeField(&self.stringify, "fixes", &.{.{ .artifactChanges = &.{.{
            .artifactLocation = .{ .uri = path },
            .replacements = &.{replacement},
        }} }});
    }

    fn ruleIndex(self: *Report, diagnostic: lint.diagnostic.Diagnostic) std.mem.Allocator.Error!usize {
        for (self.rules.items, 0..) |*rule, index| {
            if (!std.mem.eql(u8, rule.id, diagnostic.rule_id)) continue;

            // One descriptor covers all results for this rule. Any error raises
            // the descriptor's default level.
            if (diagnostic.severity == .@"error") rule.defaultConfiguration.level = "error";

            return index;
        }

        // Descriptors are emitted at finish, after per-file diagnostic arenas can
        // expire. Copy the ID while the diagnostic is still valid.
        const id = try self.gpa.dupe(u8, diagnostic.rule_id);
        errdefer self.gpa.free(id);

        try self.rules.append(self.gpa, .{
            .id = id,
            .defaultConfiguration = .{ .level = levelName(diagnostic.severity) },
        });

        return self.rules.items.len - 1;
    }

    fn region(value: lint.diagnostic.Range) Region {
        return .{
            .startLine = value.start.line + 1,
            .startColumn = value.start.column + 1,
            .endLine = value.end.line + 1,
            .endColumn = value.end.column + 1,
        };
    }
};

fn writeField(stringify: *std.json.Stringify, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn levelName(severity: lint.diagnostic.Severity) []const u8 {
    return switch (severity) {
        .@"error" => "error",
        .warn => "warning",
    };
}

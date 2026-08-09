const std = @import("std");

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Severity = enum {
    @"error",
    warn,
};

pub const Safety = enum {
    safe,
    unsafe,
};

pub const Maturity = enum {
    experimental,
    stable,
    deprecated,
};

pub const ContextKind = enum {
    function,
    method,
    class,
    namespace,
};

pub const Context = struct {
    kind: ContextKind,
    name: []const u8,
    range: Range,
};

pub const Fix = struct {
    range: Range,
    replacement: []const u8,
    safety: Safety,
};

pub const Suggestion = struct {
    label: []const u8,
    range: Range,
    replacement: []const u8,
};

pub const RuleScope = enum {
    language,
    project,
};

pub const Diagnostic = struct {
    rule_id: []const u8,
    language: []const u8,
    message: []const u8,
    range: Range,
    severity: Severity = .@"error",
    demoted: bool = false,
    maturity: Maturity = .stable,
    fingerprint: []const u8 = "",
    context: []const Context = &.{},
    fix: ?Fix = null,
    suggestions: []const Suggestion = &.{},
    capped: bool = false,
    rule_scope: RuleScope = .language,

    pub fn jsonStringify(self: Diagnostic, stringify: anytype) !void {
        // rule_scope is internal cap metadata and is not part of the wire format.
        try stringify.write(.{
            .rule_id = self.rule_id,
            .language = self.language,
            .message = self.message,
            .range = self.range,
            .severity = self.severity,
            .demoted = self.demoted,
            .maturity = self.maturity,
            .fingerprint = self.fingerprint,
            .context = self.context,
            .fix = self.fix,
            .suggestions = self.suggestions,
            .capped = self.capped,
        });
    }
};

pub const Report = struct {
    language: []const u8,
    diagnostics: []const Diagnostic,
    clean: bool,
};

pub fn hasErrors(diagnostics: []const Diagnostic) bool {
    for (diagnostics) |d| {
        if (d.severity == .@"error") return true;
    }

    return false;
}

pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
    if (a.range.start.column != b.range.start.column) return a.range.start.column < b.range.start.column;
    if (a.range.end.line != b.range.end.line) return a.range.end.line > b.range.end.line;
    if (a.range.end.column != b.range.end.column) return a.range.end.column > b.range.end.column;

    switch (std.mem.order(u8, a.rule_id, b.rule_id)) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.order(u8, a.message, b.message) == .lt,
    }
}

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

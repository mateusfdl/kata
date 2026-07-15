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

pub const Diagnostic = struct {
    rule_id: []const u8,
    language: []const u8,
    message: []const u8,
    range: Range,
    severity: Severity = .@"error",
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

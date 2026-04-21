pub const severity_error = "error";

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Diagnostic = struct {
    rule_id: []const u8,
    language: []const u8,
    severity: []const u8,
    message: []const u8,
    range: Range,
};

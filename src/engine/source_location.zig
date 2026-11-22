pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

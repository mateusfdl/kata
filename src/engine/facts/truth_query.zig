pub const Truth = enum {
    no,
    yes,
    unknown,

    pub fn negate(self: Truth) Truth {
        return switch (self) {
            .no => .yes,
            .yes => .no,
            .unknown => .unknown,
        };
    }

    pub fn conjoin(self: Truth, other: Truth) Truth {
        if (self == .no or other == .no) return .no;
        if (self == .unknown or other == .unknown) return .unknown;

        return .yes;
    }
};

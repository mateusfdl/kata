pub const RuleOverflow = struct {
    rule_id: []const u8,
    suppressed: usize,
    files: usize,
};

pub const Counts = struct {
    files: usize = 0,
    violations: usize = 0,
    warnings: usize = 0,

    pub fn add(self: *Counts, other: Counts) void {
        self.files += other.files;
        self.violations += other.violations;
        self.warnings += other.warnings;
    }
};

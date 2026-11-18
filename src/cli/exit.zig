pub const Exit = enum(u8) {
    clean = 0,
    violations = 2,
    usage = 64,
    internal_error = 70,
};

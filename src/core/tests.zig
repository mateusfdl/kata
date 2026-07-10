const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("core.zig");
    _ = @import("diagnostic_test.zig");
    _ = @import("expr_test.zig");
    _ = @import("glob_test.zig");
    _ = @import("language_test.zig");
}

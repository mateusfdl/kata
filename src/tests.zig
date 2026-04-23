const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("diagnostic_test.zig");
    _ = @import("language_test.zig");
    _ = @import("engine_test.zig");
    _ = @import("cli_test.zig");
}

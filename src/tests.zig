const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("diagnostic_test.zig");
    _ = @import("language_test.zig");
    _ = @import("engine_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("protocol_test.zig");
    _ = @import("daemon_test.zig");
    _ = @import("config_test.zig");
    _ = @import("loader_test.zig");
}

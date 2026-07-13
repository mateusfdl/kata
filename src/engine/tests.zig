const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("engine.zig");
    _ = @import("convert_test.zig");
    _ = @import("diagnostic_test.zig");
    _ = @import("expr_test.zig");
    _ = @import("family_test.zig");
    _ = @import("glob_test.zig");
    _ = @import("language_test.zig");
    _ = @import("matcher_test.zig");
    _ = @import("metric_test.zig");
    _ = @import("node_kinds_test.zig");
    _ = @import("node_test.zig");
    _ = @import("parse_test.zig");
    _ = @import("query_test.zig");
    _ = @import("rule_compiler_test.zig");
}

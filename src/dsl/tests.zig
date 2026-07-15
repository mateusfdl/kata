const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("bytes_test.zig");
    _ = @import("dsl.zig");
    _ = @import("fact_compile_test.zig");
    _ = @import("lower_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("tokenizer_test.zig");
}

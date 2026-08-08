const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("shared.zig");
    _ = @import("containing_interval_test.zig");
    _ = @import("dense_multi_map_test.zig");
    _ = @import("edit_planner_test.zig");
    _ = @import("group_cap_test.zig");
    _ = @import("group_index_test.zig");
    _ = @import("interval_test.zig");
    _ = @import("lexical_path_test.zig");
    _ = @import("node_pool_test.zig");
    _ = @import("owned_arena_test.zig");
    _ = @import("scratch_memory_test.zig");
    _ = @import("sorted_slice_test.zig");
    _ = @import("stack_test.zig");
    _ = @import("staged_matcher_test.zig");
    _ = @import("static_allocator_test.zig");
    _ = @import("table_memory_test.zig");
}

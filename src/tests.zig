const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("lint/node_test.zig");
    _ = @import("lint/rule_compiler_test.zig");
    _ = @import("lint/node_kinds_test.zig");
    _ = @import("lint/kinds_test.zig");
    _ = @import("lint/query_test.zig");
    _ = @import("lint/convert_test.zig");
    _ = @import("lint/engine_test.zig");
    _ = @import("lint/facts_test.zig");
    _ = @import("lint/project_rule_test.zig");
    _ = @import("lint/fact_rule_test.zig");
    _ = @import("lint/compile_test.zig");
    _ = @import("cli/check_test.zig");
    _ = @import("reports/text_test.zig");
    _ = @import("reports/json_test.zig");
    _ = @import("reports/pretty_test.zig");
    _ = @import("cli/query_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("server/protocol_test.zig");
    _ = @import("server/daemon_test.zig");
    _ = @import("sources/config_test.zig");
    _ = @import("sources/context_test.zig");
    _ = @import("sources/loader_test.zig");
    _ = @import("fs/source_test.zig");
    _ = @import("fs/discover_test.zig");
    _ = @import("fs/rules_test.zig");
    _ = @import("cli/new_rule_test.zig");
    _ = @import("cli/harness_test.zig");
}

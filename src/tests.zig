const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("lint/diagnostic_test.zig");
    _ = @import("lint/node_test.zig");
    _ = @import("lint/node_kinds_test.zig");
    _ = @import("lint/query_test.zig");
    _ = @import("lint/language_test.zig");
    _ = @import("lint/engine_test.zig");
    _ = @import("lint/expr_test.zig");
    _ = @import("lint/metric_test.zig");
    _ = @import("lint/facts_test.zig");
    _ = @import("lint/project_rule_test.zig");
    _ = @import("lint/fact_rule_test.zig");
    _ = @import("lint/glob_test.zig");
    _ = @import("dsl.zig");
    _ = @import("dsl/lower_test.zig");
    _ = @import("dsl/compile_test.zig");
    _ = @import("dsl/fact_compile_test.zig");
    _ = @import("dsl/parser_test.zig");
    _ = @import("dsl/tokenizer_test.zig");
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
    _ = @import("cli/new_rule_test.zig");
    _ = @import("cli/harness_test.zig");
}

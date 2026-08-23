const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    _ = @import("engine/caps_test.zig");
    _ = @import("engine/engine_test.zig");
    _ = @import("engine/dispatch_test.zig");
    _ = @import("engine/baseline_test.zig");
    _ = @import("engine/edits_test.zig");
    _ = @import("engine/fingerprint_test.zig");
    _ = @import("engine/facts_test.zig");
    _ = @import("engine/project_rule_test.zig");
    _ = @import("engine/fact_rule_test.zig");
    _ = @import("engine/compile_test.zig");
    _ = @import("cli/check_test.zig");
    _ = @import("reports/text_test.zig");
    _ = @import("reports/json_test.zig");
    _ = @import("reports/sarif_test.zig");
    _ = @import("reports/pretty_test.zig");
    _ = @import("cli/query_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("server/client_test.zig");
    _ = @import("server/context_cache_test.zig");
    _ = @import("server/protocol_test.zig");
    _ = @import("server/replay_test.zig");
    _ = @import("server/daemon_test.zig");
    _ = @import("sources/config_test.zig");
    _ = @import("sources/lifecycle_test.zig");
    _ = @import("sources/retired_test.zig");
    _ = @import("sources/context_test.zig");
    _ = @import("sources/loader_test.zig");
    _ = @import("git/git_test.zig");
    _ = @import("fs/gitignore_parity_test.zig");
    _ = @import("fs/gitignore_test.zig");
    _ = @import("fs/source_test.zig");
    _ = @import("fs/discover_test.zig");
    _ = @import("fs/process_test.zig");
    _ = @import("fs/result_cache_test.zig");
    _ = @import("fs/rules_test.zig");
    _ = @import("cli/new_rule_test.zig");
    _ = @import("cli/harness_test.zig");
}

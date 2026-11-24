pub const app = @import("app.zig").app;
pub const command = @import("command.zig").command;
pub const flagLabel = @import("flag_spec.zig").label;
pub const usageError = @import("app.zig").usageError;

test {
    _ = @import("app_test.zig");
    _ = @import("args_test.zig");
}

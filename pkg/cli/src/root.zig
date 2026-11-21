pub const app = @import("app.zig").app;
pub const command = @import("command.zig").command;
pub const flagLabel = @import("command.zig").flagLabel;
pub const usageError = @import("app.zig").usageError;

test {
    _ = @import("args_test.zig");
}

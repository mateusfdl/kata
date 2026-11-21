const cli = @import("cli");
const scenario = @import("options").scenario;

const json = .{ .name = "json", .field = .json, .value = true };
const version = .{ .name = "version", .run = run };

fn run() void {}

comptime {
    const check = cli.command(struct { json: bool = false }, .{
        .name = "check",
        .flags = switch (scenario) {
            .command_flags => .{json} ++ .{json},
            .reserved_help => .{.{ .name = "help", .field = .json, .value = true }},
            else => .{json},
        },
        .run = run,
    });
    const root = cli.command(struct { version: bool = false }, .{
        .name = "",
        .flags = if (scenario == .root_collision) .{.{ .name = "version", .field = .version, .value = true }} else .{},
        .run = run,
    });

    _ = cli.app(void, .{
        .name = "fixture",
        .commands = if (scenario == .commands) .{ check, check } else .{check},
        .default = check,
        .root = root,
        .leading_flags = if (scenario == .leading_flags) .{ version, version } else .{version},
        .help_result = {},
    });
}

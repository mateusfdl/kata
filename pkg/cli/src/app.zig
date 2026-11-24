const std = @import("std");

const args = @import("args.zig");
const flag_spec = @import("flag_spec.zig");
const names = @import("names.zig");
const usage_text = @import("usage.zig");

pub fn app(comptime Result: type, comptime spec: anytype) type {
    const leading_flags = if (@hasField(@TypeOf(spec), "leading_flags")) spec.leading_flags else .{};
    const leading_flag_names = flag_spec.texts(leading_flags);

    comptime {
        names.requireUnique("command", spec.name, &names.of(spec.commands));
        names.requireUnique("flag", spec.name, &(spec.root.flag_names ++ leading_flag_names ++ .{flag_spec.help}));
    }

    return struct {
        const usage = appUsage(spec, &leading_flag_names);

        pub fn dispatch(context: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer, argv: []const [:0]const u8) !Result {
            if (argv.len == 0) return invoke(spec.default, context, stdout, stderr, argv);

            const first = argv[0];
            if (isHelp(first)) return printHelp(stdout, usage);

            if (flag_spec.isFlag(first)) {
                inline for (leading_flags) |flag| {
                    if (std.mem.eql(u8, first, comptime flag_spec.text(flag))) return flag.run(context);
                }

                return invoke(spec.root, context, stdout, stderr, argv);
            }

            inline for (spec.commands) |cmd| {
                if (std.mem.eql(u8, first, cmd.name)) return invoke(cmd, context, stdout, stderr, argv[1..]);
            }

            return usageError(stderr, "unknown subcommand: \"{s}\"\n{s}", .{ first, usage });
        }

        fn invoke(comptime cmd: type, context: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer, argv: []const [:0]const u8) !Result {
            for (argv) |arg| {
                if (isHelp(arg)) return printHelp(stdout, cmd.usage(spec.name));
            }

            return switch (cmd.parse(argv)) {
                .ok => |options| cmd.run(context, options),
                .invalid => |invalid| reportInvalid(cmd, stderr, invalid),
            };
        }

        fn reportInvalid(comptime cmd: type, stderr: *std.Io.Writer, invalid: args.Invalid) !Result {
            const label = if (cmd.name.len == 0) spec.name else spec.name ++ " " ++ cmd.name;
            const cmd_usage = cmd.usage(spec.name);

            return switch (invalid) {
                .unexpected => |arg| usageError(stderr, "{s}: unexpected argument \"{s}\"\n{s}", .{ label, arg, cmd_usage }),
                .missing_value => |flag| usageError(stderr, "{s}: \"{s}\" requires a value\n{s}", .{ label, flag, cmd_usage }),
                .missing_flag => |message| usageError(stderr, "{s}: {s}\n", .{ label, message }),
                .missing_positional => usageError(stderr, "{s}", .{cmd_usage}),
            };
        }

        fn printHelp(stdout: *std.Io.Writer, text: []const u8) !Result {
            try stdout.writeAll(text);
            try stdout.flush();

            return spec.help_result;
        }
    };
}

pub fn usageError(stderr: *std.Io.Writer, comptime fmt: []const u8, values: anytype) (std.Io.Writer.Error || error{UsageReported}) {
    try stderr.print(fmt, values);
    try stderr.flush();

    return error.UsageReported;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, flag_spec.help);
}

fn appUsage(comptime spec: anytype, comptime leading_flag_names: []const []const u8) []const u8 {
    const program = spec.name;

    var text: []const u8 = "";
    if (spec.default.name.len > 0) {
        text = text ++ usage_text.line(&.{program ++ "  (same as " ++ program ++ " " ++ spec.default.name ++ ")"});
    }

    for (spec.commands) |cmd| text = text ++ cmd.usage(program);
    text = text ++ spec.root.usage(program);
    for (leading_flag_names) |flag_name| text = text ++ usage_text.line(&.{ program, flag_name });

    return text ++ usage_text.line(&.{ program, flag_spec.help });
}

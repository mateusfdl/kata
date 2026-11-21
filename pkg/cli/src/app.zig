const std = @import("std");

const args = @import("args.zig");
const names = @import("names.zig");

pub fn app(comptime Result: type, comptime spec: anytype) type {
    const leading_flags = if (@hasField(@TypeOf(spec), "leading_flags")) spec.leading_flags else .{};

    comptime {
        names.requireUnique("command", spec.name, &names.list(spec.commands, ""));
        const root_flags = spec.root.flag_names ++ names.list(leading_flags, "--") ++ .{names.help};
        names.requireUnique("flag", spec.name, &root_flags);
    }

    return struct {
        const usage = blk: {
            var text: []const u8 = if (spec.default.name.len > 0)
                "usage: " ++ spec.name ++ "  (same as " ++ spec.name ++ " " ++ spec.default.name ++ ")\n"
            else
                "";
            for (spec.commands) |cmd| text = text ++ cmd.usage(spec.name);
            text = text ++ spec.root.usage(spec.name);
            for (leading_flags) |flag| text = text ++ "usage: " ++ spec.name ++ " --" ++ flag.name ++ "\n";

            break :blk text ++ "usage: " ++ spec.name ++ " " ++ names.help ++ "\n";
        };

        pub fn dispatch(context: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer, argv: []const [:0]const u8) !Result {
            if (argv.len == 0) return invoke(spec.default, context, stdout, stderr, argv);
            if (std.mem.eql(u8, argv[0], names.help)) return printHelp(stdout, usage);
            if (args.isFlag(argv[0])) {
                inline for (leading_flags) |flag| {
                    if (std.mem.eql(u8, argv[0], "--" ++ flag.name)) return flag.run(context);
                }

                return invoke(spec.root, context, stdout, stderr, argv);
            }

            inline for (spec.commands) |cmd| {
                if (std.mem.eql(u8, argv[0], cmd.name)) return invoke(cmd, context, stdout, stderr, argv[1..]);
            }

            return usageError(stderr, "unknown subcommand: \"{s}\"\n" ++ usage, .{argv[0]});
        }

        fn invoke(comptime cmd: type, context: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer, argv: []const [:0]const u8) !Result {
            for (argv) |arg| {
                if (std.mem.eql(u8, arg, names.help)) return printHelp(stdout, cmd.usage(spec.name));
            }

            const invalid = switch (cmd.parse(argv)) {
                .ok => |parsed| return cmd.run(context, parsed),
                .invalid => |invalid| invalid,
            };

            const label = if (cmd.name.len == 0) spec.name else spec.name ++ " " ++ cmd.name;
            return switch (invalid) {
                .unexpected => |arg| usageError(stderr, label ++ ": unexpected argument \"{s}\"\n" ++ cmd.usage(spec.name), .{arg}),
                .missing_value => |flag| usageError(stderr, label ++ ": \"{s}\" requires a value\n" ++ cmd.usage(spec.name), .{flag}),
                .missing_flag => |message| usageError(stderr, label ++ ": {s}\n", .{message}),
                .missing_positional => usageError(stderr, cmd.usage(spec.name), .{}),
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

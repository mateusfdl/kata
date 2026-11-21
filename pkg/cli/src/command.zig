const std = @import("std");

const args = @import("args.zig");
const names = @import("names.zig");

pub fn command(comptime Options: type, comptime spec: anytype) type {
    const flags = if (@hasField(@TypeOf(spec), "flags")) spec.flags else .{};
    const positionals = if (@hasField(@TypeOf(spec), "positionals")) spec.positionals else .{};
    const grammar = args.grammar(Options, .{ .flags = flags, .positionals = positionals });

    const declared_flags = names.list(flags, "--");
    const scope = if (spec.name.len == 0) "root command" else spec.name;
    comptime names.requireUnique("flag", scope, &(declared_flags ++ .{names.help}));

    return struct {
        pub const flag_names = declared_flags;
        pub const name = spec.name;
        pub const run = spec.run;
        pub const parse = grammar.parse;
        pub const Result = grammar.Result;
        pub const synopsis = blk: {
            var text: []const u8 = if (name.len > 0) " " ++ name else "";

            for (positionals) |pos| {
                const required = std.meta.fieldInfo(Options, pos.field).default_value_ptr == null;
                text = text ++ " " ++ argumentLabel(pos.label, required);
            }

            var i: usize = 0;
            while (i < flags.len) : (i += 1) {
                const flag = flags[i];
                const required = std.meta.fieldInfo(Options, flag.field).default_value_ptr == null;
                var label: []const u8 = "--" ++ flag.name;
                if (@hasField(@TypeOf(flag), "value")) {
                    while (i + 1 < flags.len and flags[i + 1].field == flag.field and @hasField(@TypeOf(flags[i + 1]), "value")) {
                        i += 1;
                        label = label ++ "|--" ++ flags[i].name;
                    }
                } else {
                    label = label ++ " " ++ flag.label;
                }

                text = text ++ " " ++ argumentLabel(label, required);
            }

            if (@hasField(@TypeOf(spec), "stdin")) text = text ++ " < " ++ spec.stdin;
            break :blk text;
        };
    };
}

fn argumentLabel(comptime label: []const u8, comptime required: bool) []const u8 {
    return if (required) label else "[" ++ label ++ "]";
}

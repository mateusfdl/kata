const std = @import("std");

const flag_prefix = "--";

pub const Invalid = union(enum) {
    unexpected: []const u8,
    missing_value: []const u8,
    missing_positional,
    missing_flag: []const u8,
};

pub fn isFlag(value: []const u8) bool {
    return std.mem.startsWith(u8, value, flag_prefix);
}

pub fn grammar(comptime Options: type, comptime spec: anytype) type {
    comptime {
        for (@typeInfo(Options).@"struct".fields) |field| {
            if (field.default_value_ptr != null) continue;

            for (spec.positionals) |pos| {
                if (std.mem.eql(u8, @tagName(pos.field), field.name)) break;
            } else {
                for (spec.flags) |flag| {
                    if (std.mem.eql(u8, @tagName(flag.field), field.name)) break;
                } else @compileError("no argument supplies field '" ++ field.name ++ "'");
            }
        }
    }

    return struct {
        const Supplied = [@typeInfo(Options).@"struct".fields.len]bool;

        pub const Result = union(enum) {
            ok: Options,
            invalid: Invalid,
        };

        pub fn parse(argv: []const [:0]const u8) Result {
            var options: Options = undefined;

            inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.defaultValue()) |default| {
                    @field(options, field.name) = default;
                }
            }

            var supplied: Supplied = @splat(false);
            var positionals_seen: usize = 0;
            var i: usize = 0;
            while (i < argv.len) : (i += 1) {
                const invalid = if (isFlag(argv[i]))
                    applyFlag(&options, argv, &i, &supplied)
                else
                    applyPositional(&options, argv[i], &positionals_seen);

                if (invalid) |problem| return .{ .invalid = problem };
            }

            inline for (spec.positionals, 0..) |pos, index| {
                const required = comptime std.meta.fieldInfo(Options, pos.field).default_value_ptr == null;
                if (required and index >= positionals_seen) return .{ .invalid = .missing_positional };
            }

            inline for (spec.flags) |flag| {
                if (comptime std.meta.fieldInfo(Options, flag.field).default_value_ptr == null) {
                    const index = comptime std.meta.fieldIndex(Options, @tagName(flag.field)).?;
                    const hint = if (@hasField(@TypeOf(flag), "hint")) flag.hint else "";
                    if (!supplied[index]) return .{ .invalid = .{ .missing_flag = "--" ++ flag.name ++ " is required" ++ hint } };
                }
            }

            return .{ .ok = options };
        }

        fn applyPositional(options: *Options, arg: []const u8, seen: *usize) ?Invalid {
            inline for (spec.positionals, 0..) |pos, index| {
                if (index == seen.*) {
                    @field(options, @tagName(pos.field)) = arg;
                    seen.* += 1;

                    return null;
                }
            }

            return .{ .unexpected = arg };
        }

        /// `i` is the index of the flag. A flag that takes the next argument
        /// as its value moves `i` to that argument.
        fn applyFlag(options: *Options, argv: []const [:0]const u8, i: *usize, supplied: *Supplied) ?Invalid {
            const arg = argv[i.*];

            inline for (spec.flags) |flag| match: {
                const text = flag_prefix ++ flag.name;
                const field = @tagName(flag.field);
                const index = comptime std.meta.fieldIndex(Options, field).?;

                if (@hasField(@TypeOf(flag), "value")) {
                    if (!std.mem.eql(u8, arg, text)) break :match;
                    @field(options, field) = flag.value;
                } else if (std.mem.eql(u8, arg, text)) {
                    if (i.* + 1 >= argv.len or isFlag(argv[i.* + 1])) return .{ .missing_value = arg };

                    i.* += 1;
                    @field(options, field) = argv[i.*];
                } else if (std.mem.startsWith(u8, arg, text ++ "=")) {
                    @field(options, field) = arg[text.len + 1 ..];
                } else break :match;

                supplied[index] = true;
                return null;
            }

            return .{ .unexpected = arg };
        }
    };
}

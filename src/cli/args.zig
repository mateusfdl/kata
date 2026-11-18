const std = @import("std");

const flag_prefix = "--";

pub const Invalid = union(enum) {
    unexpected: []const u8,
    missing_value: []const u8,
    missing_positional,
};

pub fn isFlag(value: []const u8) bool {
    return std.mem.startsWith(u8, value, flag_prefix);
}

/// The grammar of one command, parsed straight into its `Options`.
///
/// `spec.flags` is a tuple. `.{ .name, .field }` is a flag that takes a value.
/// `.{ .name, .field, .value }` is a flag that assigns a constant. Arguments
/// apply in order, so the last flag that targets a field wins.
///
/// `spec.positionals` is a tuple of field names, filled in order. A positional
/// is required when its field has no default.
pub fn grammar(comptime Options: type, comptime spec: anytype) type {
    comptime {
        for (@typeInfo(Options).@"struct".fields) |field| {
            if (field.default_value_ptr != null) continue;

            var positional = false;
            for (spec.positionals) |name| {
                if (std.mem.eql(u8, @tagName(name), field.name)) {
                    positional = true;
                }
            }

            if (!positional) @compileError("field '" ++ field.name ++ "' needs a default or a positional");
        }
    }

    return struct {
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

            var positionals_seen: usize = 0;
            var i: usize = 0;
            while (i < argv.len) : (i += 1) {
                const invalid = if (isFlag(argv[i]))
                    applyFlag(&options, argv, &i)
                else
                    applyPositional(&options, argv[i], &positionals_seen);

                if (invalid) |problem| return .{ .invalid = problem };
            }

            inline for (spec.positionals, 0..) |name, index| {
                const required = comptime std.meta.fieldInfo(Options, name).default_value_ptr == null;
                if (required and index >= positionals_seen) return .{ .invalid = .missing_positional };
            }

            return .{ .ok = options };
        }

        fn applyPositional(options: *Options, arg: []const u8, seen: *usize) ?Invalid {
            inline for (spec.positionals, 0..) |name, index| {
                if (index == seen.*) {
                    @field(options, @tagName(name)) = arg;
                    seen.* += 1;

                    return null;
                }
            }

            return .{ .unexpected = arg };
        }

        /// `i` is the index of the flag. A flag that takes the next argument
        /// as its value moves `i` to that argument.
        fn applyFlag(options: *Options, argv: []const [:0]const u8, i: *usize) ?Invalid {
            const arg = argv[i.*];

            inline for (spec.flags) |flag| {
                const text = flag_prefix ++ flag.name;
                const field = @tagName(flag.field);

                if (@hasField(@TypeOf(flag), "value")) {
                    if (std.mem.eql(u8, arg, text)) {
                        @field(options, field) = flag.value;

                        return null;
                    }
                } else if (std.mem.eql(u8, arg, text)) {
                    // a separate token beginning with "--" starts another flag.
                    // use --name=value when the value itself begins with "--".
                    if (i.* + 1 >= argv.len or isFlag(argv[i.* + 1])) return .{ .missing_value = arg };

                    i.* += 1;
                    @field(options, field) = argv[i.*];

                    return null;
                } else if (std.mem.startsWith(u8, arg, text ++ "=")) {
                    @field(options, field) = arg[text.len + 1 ..];

                    return null;
                }
            }

            return .{ .unexpected = arg };
        }
    };
}

const std = @import("std");

const flag_spec = @import("flag_spec.zig");

pub const Invalid = union(enum) {
    unexpected: []const u8,
    missing_value: []const u8,
    missing_positional,
    missing_flag: []const u8,
};

pub fn isRequired(comptime Options: type, comptime field: std.meta.FieldEnum(Options)) bool {
    return std.meta.fieldInfo(Options, field).default_value_ptr == null;
}

pub fn grammar(comptime Options: type, comptime spec: anytype) type {
    comptime requireSourceForEveryField(Options, spec);

    return struct {
        const Field = std.meta.FieldEnum(Options);

        pub const Result = union(enum) {
            ok: Options,
            invalid: Invalid,
        };

        pub fn parse(argv: []const [:0]const u8) Result {
            var parser: Parser = .{ .options = defaults(), .remaining = argv };

            while (parser.next()) |arg| {
                const invalid = if (flag_spec.isFlag(arg)) parser.applyFlag(arg) else parser.applyPositional(arg);
                if (invalid) |problem| return .{ .invalid = problem };
            }

            if (parser.missingArgument()) |problem| return .{ .invalid = problem };

            return .{ .ok = parser.options };
        }

        fn defaults() Options {
            var options: Options = undefined;
            inline for (std.meta.fields(Options)) |field| {
                if (field.defaultValue()) |default| @field(options, field.name) = default;
            }

            return options;
        }

        const Parser = struct {
            options: Options,
            remaining: []const [:0]const u8,
            supplied: [std.meta.fields(Options).len]bool = @splat(false),
            positionals_seen: usize = 0,

            fn next(parser: *Parser) ?[]const u8 {
                if (parser.remaining.len == 0) return null;
                defer parser.remaining = parser.remaining[1..];

                return parser.remaining[0];
            }

            fn nextValue(parser: *Parser) ?[]const u8 {
                if (parser.remaining.len == 0 or flag_spec.isFlag(parser.remaining[0])) return null;

                return parser.next();
            }

            fn set(parser: *Parser, comptime field: Field, value: @FieldType(Options, @tagName(field))) void {
                @field(parser.options, @tagName(field)) = value;
                parser.supplied[@intFromEnum(field)] = true;
            }

            fn applyPositional(parser: *Parser, arg: []const u8) ?Invalid {
                inline for (spec.positionals, 0..) |positional, index| {
                    if (index == parser.positionals_seen) {
                        parser.set(positional.field, arg);
                        parser.positionals_seen += 1;

                        return null;
                    }
                }

                return .{ .unexpected = arg };
            }

            fn applyFlag(parser: *Parser, arg: []const u8) ?Invalid {
                const separator = std.mem.indexOfScalar(u8, arg, '=');
                const name = arg[0 .. separator orelse arg.len];
                const attached: ?[]const u8 = if (separator) |index| arg[index + 1 ..] else null;

                inline for (spec.flags) |flag| {
                    if (std.mem.eql(u8, name, comptime flag_spec.text(flag))) {
                        return if (comptime flag_spec.isConstant(flag))
                            parser.applyConstantFlag(flag, arg, attached)
                        else
                            parser.applyValueFlag(flag, arg, attached);
                    }
                }

                return .{ .unexpected = arg };
            }

            fn applyConstantFlag(parser: *Parser, comptime flag: anytype, arg: []const u8, attached: ?[]const u8) ?Invalid {
                if (attached != null) return .{ .unexpected = arg };

                parser.set(flag.field, flag.value);
                return null;
            }

            fn applyValueFlag(parser: *Parser, comptime flag: anytype, arg: []const u8, attached: ?[]const u8) ?Invalid {
                const value = attached orelse parser.nextValue() orelse return .{ .missing_value = arg };

                parser.set(flag.field, value);
                return null;
            }

            fn missingArgument(parser: *const Parser) ?Invalid {
                inline for (spec.positionals, 0..) |positional, index| {
                    const required = comptime isRequired(Options, positional.field);
                    if (required and index >= parser.positionals_seen) return .missing_positional;
                }

                inline for (spec.flags) |flag| {
                    const required = comptime isRequired(Options, flag.field);
                    if (required and !parser.supplied[@intFromEnum(@as(Field, flag.field))]) {
                        return .{ .missing_flag = comptime flag_spec.text(flag) ++ " is required" ++ flag_spec.hint(flag) };
                    }
                }

                return null;
            }
        };
    };
}

fn requireSourceForEveryField(comptime Options: type, comptime spec: anytype) void {
    for (std.meta.fields(Options)) |field| {
        if (field.default_value_ptr != null) continue;
        if (targets(spec.positionals, field.name) or targets(spec.flags, field.name)) continue;

        @compileError("no argument supplies field '" ++ field.name ++ "'");
    }
}

fn targets(comptime entries: anytype, comptime field_name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, @tagName(entry.field), field_name)) return true;
    }

    return false;
}

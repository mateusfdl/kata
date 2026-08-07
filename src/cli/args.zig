const std = @import("std");

pub const env_baseline = "KATA_BASELINE";
pub const env_socket = "KATA_SOCKET";
pub const env_runtime_dir = "XDG_RUNTIME_DIR";
const flag_prefix = "--";

pub const CommandName = enum {
    daemon,
    check,
    facts,
    @"test",
    query,
    stop,
    @"new-rule",
};

pub const Spec = struct {
    name: []const u8,
    kind: enum { boolean, arg },

    pub fn isFlag(value: []const u8) bool {
        return std.mem.startsWith(u8, value, flag_prefix);
    }
};

pub fn parser(comptime specs: []const Spec) type {
    return struct {
        pub const Flags = flags_type: {
            const Attributes = std.builtin.Type.StructField.Attributes;
            var names: [specs.len][]const u8 = undefined;
            var types: [specs.len]type = undefined;
            var attrs: [specs.len]Attributes = undefined;
            for (specs, &names, &types, &attrs) |spec, *name, *ty, *attr| {
                name.* = spec.name;
                switch (spec.kind) {
                    .boolean => {
                        ty.* = usize;
                        attr.* = .{ .default_value_ptr = &@as(usize, 0) };
                    },
                    .arg => {
                        ty.* = ?[:0]const u8;
                        attr.* = .{ .default_value_ptr = &@as(ty.*, null) };
                    },
                }
            }
            break :flags_type @Struct(.auto, null, &names, &types, &attrs);
        };

        pub const Result = struct {
            flags: Flags = .{},
            positional_buf: [8][:0]const u8 = undefined,
            positional_len: usize = 0,
            unknown: ?[]const u8 = null,
            missing: ?[]const u8 = null,

            pub fn positionals(self: *const Result) []const [:0]const u8 {
                return self.positional_buf[0..self.positional_len];
            }
        };

        pub fn parse(args: []const [:0]const u8) Result {
            var result: Result = .{};

            var i: usize = 0;
            arg_loop: while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (!Spec.isFlag(arg)) {
                    if (result.positional_len < result.positional_buf.len) {
                        result.positional_buf[result.positional_len] = arg;
                        result.positional_len += 1;
                    }

                    continue;
                }

                inline for (specs) |spec| {
                    const flag = flag_prefix ++ spec.name;
                    if (std.mem.eql(u8, arg, flag)) {
                        switch (spec.kind) {
                            // Store a one-based position instead of a boolean. Zero means
                            // absent, and callers can select the last conflicting flag.
                            .boolean => @field(result.flags, spec.name) = i + 1,
                            .arg => {
                                // A separate token beginning with "--" starts another flag.
                                // Use --name=value when the value itself begins with "--".
                                if (i + 1 >= args.len or Spec.isFlag(args[i + 1])) {
                                    if (result.missing == null) result.missing = arg;
                                } else {
                                    i += 1;

                                    @field(result.flags, spec.name) = args[i];
                                }
                            },
                        }

                        continue :arg_loop;
                    }

                    if (spec.kind == .arg and std.mem.startsWith(u8, arg, flag ++ "=")) {
                        @field(result.flags, spec.name) = arg[flag.len + 1 ..];

                        continue :arg_loop;
                    }
                }

                if (result.unknown == null) result.unknown = arg;
            }

            return result;
        }
    };
}

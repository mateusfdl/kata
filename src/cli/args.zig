const std = @import("std");

pub const env_rules_dir = "KATA_RULES_DIR";
pub const env_socket = "KATA_SOCKET";
pub const env_runtime_dir = "XDG_RUNTIME_DIR";
pub const fallback_socket_path = "/tmp/kata.sock";

const flag_prefix = "--";

pub const Flag = enum {
    filename,
    lang,
    root,

    pub fn name(self: Flag) []const u8 {
        return @tagName(self);
    }
};

pub const CommandName = enum {
    daemon,
    check,
    facts,
    @"test",
    query,
    stop,
    @"new-rule",

    pub fn parse(value: []const u8) ?CommandName {
        inline for (std.meta.fields(CommandName)) |field| {
            const command: CommandName = @enumFromInt(field.value);
            if (std.mem.eql(u8, value, @tagName(command))) return command;
        }
        return null;
    }

    pub fn text(self: CommandName) []const u8 {
        return @tagName(self);
    }
};

pub const FlagValue = union(enum) {
    found: []const u8,
    missing,
    absent,
};

pub fn valueFor(args: []const [:0]const u8, index: *usize, flag: Flag) FlagValue {
    const value = args[index.*];
    const name = flag.name();
    const flag_len = flag_prefix.len + name.len;

    if (!std.mem.startsWith(u8, value, flag_prefix)) return .absent;
    if (value.len < flag_len) return .absent;
    if (!std.mem.eql(u8, value[flag_prefix.len..flag_len], name)) return .absent;

    if (value.len == flag_len) {
        if (index.* + 1 >= args.len) return .missing;
        index.* += 1;
        return .{ .found = args[index.*] };
    }

    if (value.len == flag_len + 1) return .absent;
    if (value[flag_len] != '=') return .absent;
    return .{ .found = value[flag_len + 1 ..] };
}

pub fn firstPositional(values: []const [:0]const u8) ?[]const u8 {
    for (values) |value| {
        if (!std.mem.startsWith(u8, value, flag_prefix)) return value;
    }
    return null;
}

pub fn isFlag(value: []const u8) bool {
    return std.mem.startsWith(u8, value, flag_prefix);
}

const args = @import("args.zig");
const flag_spec = @import("flag_spec.zig");
const names = @import("names.zig");
const usage_text = @import("usage.zig");

pub fn command(comptime Options: type, comptime spec: anytype) type {
    const flags = if (@hasField(@TypeOf(spec), "flags")) spec.flags else .{};
    const positionals = if (@hasField(@TypeOf(spec), "positionals")) spec.positionals else .{};
    const generated_forms = .{usage_text.arguments(Options, positionals, flags)};
    const usage_forms = if (@hasField(@TypeOf(spec), "usage_forms")) spec.usage_forms else generated_forms;

    const grammar = args.grammar(Options, .{ .flags = flags, .positionals = positionals });

    const declared_flags = flag_spec.texts(flags);
    const scope = if (spec.name.len == 0) "root command" else spec.name;
    comptime names.requireUnique("flag", scope, &(declared_flags ++ .{flag_spec.help}));

    return struct {
        pub const flag_names = declared_flags;
        pub const name = spec.name;
        pub const run = spec.run;
        pub const parse = grammar.parse;
        pub const Result = grammar.Result;

        pub fn usage(comptime program: []const u8) []const u8 {
            return comptime usage_text.lines(program, name, usage_forms);
        }
    };
}

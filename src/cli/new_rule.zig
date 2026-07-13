const std = @import("std");

const exit = @import("exit.zig");
const output = @import("output.zig");
const fs = @import("../fs.zig");
const lint = @import("engine");

const language = lint.language;
const rule = lint.rule;

pub const exit_clean = exit.clean;
pub const exit_usage = exit.usage;
pub const exit_internal_error = exit.internal_error;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Options = struct {
    args: []const [:0]const u8,
    user_rules_dir: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) Error!u8 {
    if (opts.args.len != 3)
        return output.message(opts.stderr, "usage: kata new-rule <ts|tsx|go> <rule-id>\n", exit_usage);

    const lang_str = opts.args[1];
    const id = opts.args[2];

    const lang = language.Name.fromString(lang_str) orelse
        return output.format(opts.stderr, "unknown language: \"{s}\" (expected " ++ language.supported_list ++ ")\n", .{lang_str}, exit_usage);

    if (!rule.isValidId(id))
        return output.format(opts.stderr, "invalid rule id: \"{s}\" (must match [A-Za-z0-9_-]+)\n", .{id}, exit_usage);

    const root = opts.user_rules_dir orelse
        return output.message(opts.stderr, "cannot resolve user rules directory: set XDG_CONFIG_HOME or HOME\n", exit_usage);

    const lang_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, lang.toString() });
    const file_path = try std.fmt.allocPrint(arena, "{s}/{s}.kata", .{ lang_dir, id });
    const body = try renderTemplate(arena, lang, id);

    fs.rules.createNew(io, lang_dir, file_path, body) catch |err| switch (err) {
        error.PathAlreadyExists => return output.format(opts.stderr, "path already exists: {s}\n", .{file_path}, exit_usage),
        else => return output.format(opts.stderr, "write rule {s}: {s}\n", .{ file_path, @errorName(err) }, exit_internal_error),
    };

    return output.format(opts.stdout, "{s}\nadd {s}/{s} to 'enabled' in rules.yaml to activate it\n", .{ file_path, lang.toString(), id }, exit_clean);
}

fn renderTemplate(arena: std.mem.Allocator, lang: language.Name, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\rule {s} {{
        \\  lang {s}
        \\  match identifier @match
        \\  emit @match {{ message "TODO: explain why this is bad" }}
        \\}}
        \\
    , .{ id, lang.toString() });
}

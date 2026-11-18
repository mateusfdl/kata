const std = @import("std");

const args = @import("args.zig");
const fs = @import("../fs.zig");
const lint = @import("engine");
const output = @import("output.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const language = lint.language;
const rule = lint.rule;

pub const name = "new-rule";
pub const synopsis = "new-rule <" ++ language.pipe_list ++ "> <rule-id>";

pub const Args = struct {
    lang: []const u8,
    id: []const u8,
};

pub const grammar = args.grammar(Args, .{ .flags = .{}, .positionals = .{ .lang, .id } });

pub fn execute(env: Env, parsed: Args) !Exit {
    const arena = env.arena;
    const id = parsed.id;

    const lang = language.Name.fromString(parsed.lang) orelse
        return output.usage(env.stderr, "unknown language: \"{s}\" (expected " ++ language.supported_list ++ ")\n", .{parsed.lang});

    if (!rule.isValidId(id))
        return output.usage(env.stderr, "invalid rule id: \"{s}\" (must match [A-Za-z0-9_-]+)\n", .{id});

    const root = (try fs.config.resolveUserRules(arena, env.environ)) orelse
        return output.usage(env.stderr, "cannot resolve user rules directory: set XDG_CONFIG_HOME or HOME\n", .{});

    const lang_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, lang.toString() });
    const file_path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ lang_dir, id, fs.rules.kata_suffix });
    const body = try renderTemplate(arena, lang, id);

    fs.rules.createNew(env.io, lang_dir, file_path, body) catch |err| switch (err) {
        error.PathAlreadyExists => return output.usage(env.stderr, "path already exists: {s}\n", .{file_path}),
        else => return output.failure(env.stderr, "write rule {s}: {s}\n", .{ file_path, @errorName(err) }),
    };

    try env.stdout.print("{s}\nadd '{s}:' under 'rules: {s}:' in rules.yaml to activate it\n", .{ file_path, id, lang.toString() });
    try env.stdout.flush();

    return .clean;
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

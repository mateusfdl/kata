const std = @import("std");

const cli = @import("cli");
const analysis = @import("analysis.zig");
const dsl = @import("dsl");
const lint = @import("engine");
const output = @import("output.zig");
const report_flags = @import("report_flags.zig");
const reports = @import("../reports.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const Engine = lint.Engine;
const language = lint.language;

const rule_id = "query";

pub const Args = struct {
    text: []const u8,
    target: []const u8 = ".",
    lang: []const u8,
    format: reports.Format = .pretty,
};

pub const command = cli.command(Args, .{
    .name = "query",
    .positionals = .{
        .{ .field = .text, .label = "'<kata rule>'" },
        .{ .field = .target, .label = "path" },
    },
    .flags = .{
        .{
            .name = "lang",
            .field = .lang,
            .label = "<" ++ language.pipe_list ++ ">",
            .hint = " (expected " ++ language.supported_list ++ ")",
        },
    } ++ report_flags.format,
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    var langs: std.EnumSet(language.Name) = .initEmpty();
    var tokens = std.mem.splitScalar(u8, parsed.lang, ',');
    while (tokens.next()) |token| {
        langs.insert(language.Name.fromString(token) orelse
            return output.usage(env.stderr, "kata query: unsupported language: \"{s}\" (expected " ++ language.supported_list ++ ")\n", .{token}));
    }

    var rule_set: lint.RuleSet = .{ .allocator = env.gpa };
    defer rule_set.deinit();

    var each_lang = langs.iterator();
    while (each_lang.next()) |lang| try rule_set.append(lang, .{ .id = rule_id, .source = parsed.text });

    var engine = Engine.init(env.gpa, &rule_set, dsl.engine_compiler.ruleCompiler(), &.{});
    defer engine.deinit();

    // the rule text is an argument, so a rule that does not compile is a usage error.
    const analysis_command: analysis.Command = .{ .name = command.name, .rules_failure = error.UsageReported };

    return analysis.report(env, &engine, analysis_command, .{ .target = parsed.target }, parsed.format);
}

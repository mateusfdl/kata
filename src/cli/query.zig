const std = @import("std");

const args = @import("args.zig");
const analysis = @import("analysis.zig");
const dsl = @import("dsl");
const lint = @import("engine");
const output = @import("output.zig");
const reports = @import("../reports.zig");

const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const Engine = lint.Engine;
const language = lint.language;

pub const name = "query";
pub const synopsis = "query '<kata rule>' [path] --lang=<" ++ language.pipe_list ++ ">";

const rule_id = "query";

pub const Args = struct {
    text: []const u8,
    target: []const u8 = ".",
    lang: ?[]const u8 = null,
    format: reports.Format = .pretty,
};

pub const grammar = args.grammar(Args, .{
    .flags = .{
        .{ .name = "lang", .field = .lang },
        .{ .name = "json", .field = .format, .value = .json },
        .{ .name = "text", .field = .format, .value = .text },
        .{ .name = "sarif", .field = .format, .value = .sarif },
    },
    .positionals = .{ .text, .target },
});

pub fn execute(env: Env, parsed: Args) !Exit {
    const lang_list = parsed.lang orelse
        return output.usage(env.stderr, "kata query: --lang is required (expected " ++ language.supported_list ++ ")\n", .{});

    var langs: std.EnumSet(language.Name) = .initEmpty();
    var tokens = std.mem.splitScalar(u8, lang_list, ',');
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
    const command: analysis.Command = .{ .name = name, .rules_failure = error.UsageReported };

    return analysis.report(env, &engine, command, .{ .target = parsed.target }, parsed.format);
}

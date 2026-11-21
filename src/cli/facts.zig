const std = @import("std");

const cli = @import("cli");
const fs = @import("../fs.zig");
const lint = @import("engine");
const output = @import("output.zig");

const Workspace = @import("workspace.zig").Workspace;
const Env = @import("env.zig").Env;
const Exit = @import("exit.zig").Exit;

const fact_schema = lint.fact_schema;

pub const Args = struct {
    target: []const u8,
};

pub const command = cli.command(Args, .{
    .name = "facts",
    .positionals = .{
        .{ .field = .target, .label = "<file>" },
    },
    .run = execute,
});

pub fn execute(env: Env, parsed: Args) !Exit {
    const target = parsed.target;
    const lang = fs.source.languageOf(target) orelse
        return output.usage(env.stderr, "cannot infer language from \"{s}\"\n", .{target});

    var workspace = try Workspace.open(env, target);
    defer workspace.deinit();
    const ctx = workspace.ctx;

    const source = fs.source.read(env.io, env.gpa, target) catch |err|
        return output.internal(env.stderr, "read file", err);
    defer env.gpa.free(source);

    var file_facts = ctx.engine.extractFacts(env.gpa, source, lang, target) catch |err|
        return output.internal(env.stderr, "extract facts", err);
    defer file_facts.deinit();

    print(env.stdout, file_facts) catch |err|
        return output.internal(env.stderr, "print facts", err);

    return .clean;
}

fn print(stdout: *std.Io.Writer, file_facts: lint.facts.FileFacts) !void {
    inline for (fact_schema.descriptors) |descriptor_value| {
        for (@field(file_facts, descriptor_value.list)) |record| {
            try printRecord(stdout, descriptor_value, record);
        }
    }

    try stdout.flush();
}

fn printRecord(stdout: *std.Io.Writer, comptime descriptor_value: fact_schema.FactDescriptor, record: descriptor_value.Record) !void {
    switch (descriptor_value.kind) {
        .class => try stdout.print("class {s} @{d}:{d}\n", .{ record.name, record.range.start.line + 1, record.range.start.column + 1 }),
        .method => try stdout.print("method {s}.{s} @{d}:{d}\n", .{ orDash(record.container), record.name, record.range.start.line + 1, record.range.start.column + 1 }),
        .typed_decl => try stdout.print("decl {s}: {s} @{d}:{d}\n", .{ record.name, record.type_name, record.range.start.line + 1, record.range.start.column + 1 }),
        .call => try stdout.print("call {s}.{s} in {s} @{d}:{d}\n", .{ orDash(record.receiver), record.method, orDash(record.container), record.range.start.line + 1, record.range.start.column + 1 }),
        .import => try stdout.print("import {s} from {s}\n", .{ orDash(record.name), record.source }),
    }
}

fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

const std = @import("std");

const exit = @import("exit.zig");
const fs = @import("../fs.zig");
const output = @import("output.zig");
const lint = @import("../lint.zig");

const Engine = lint.Engine;
const language = lint.language;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const lang = switch (language.resolve("", target)) {
        .ok => |n| n,
        else => return output.format(stderr, "cannot infer language from \"{s}\"\n", .{target}, exit.usage),
    };

    const source = fs.source.read(io, gpa, target) catch |err|
        return output.internal(stderr, "read file", err, exit.internal_error);
    defer gpa.free(source);

    var file_facts = engine.extractFacts(gpa, source, lang, target) catch |err|
        return output.internal(stderr, "extract facts", err, exit.internal_error);
    defer file_facts.deinit();

    print(stdout, file_facts) catch |err|
        return output.internal(stderr, "print facts", err, exit.internal_error);

    return exit.clean;
}

fn print(stdout: *std.Io.Writer, file_facts: lint.facts.FileFacts) !void {
    for (file_facts.classes) |cl| {
        try stdout.print("class {s} @{d}:{d}\n", .{ cl.name, cl.range.start.line + 1, cl.range.start.column + 1 });
    }

    for (file_facts.methods) |m| {
        try stdout.print("method {s}.{s} @{d}:{d}\n", .{ orDash(m.container), m.name, m.range.start.line + 1, m.range.start.column + 1 });
    }

    for (file_facts.typed_decls) |d| {
        try stdout.print("decl {s}: {s} @{d}:{d}\n", .{ d.name, d.type_name, d.range.start.line + 1, d.range.start.column + 1 });
    }

    for (file_facts.calls) |call| {
        try stdout.print("call {s}.{s} in {s} @{d}:{d}\n", .{ orDash(call.receiver), call.method, orDash(call.container), call.range.start.line + 1, call.range.start.column + 1 });
    }

    for (file_facts.imports) |im| {
        try stdout.print("import {s} from {s}\n", .{ orDash(im.name), im.source });
    }

    try stdout.flush();
}

fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

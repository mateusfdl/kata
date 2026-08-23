const std = @import("std");

const exit = @import("exit.zig");
const fs = @import("../fs.zig");
const output = @import("output.zig");
const lint = @import("engine");

const Engine = lint.Engine;
const language = lint.language;
const fact_schema = lint.fact_schema;

const Presenter = struct {
    stdout: *std.Io.Writer,

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
            else => {
                return output.format(stderr, "cannot infer language from \"{s}\"\n", .{target}, exit.usage);
            },
        };

        const source = fs.source.read(io, gpa, target) catch |err|
            return output.internal(stderr, "read file", err, exit.internal_error);
        defer gpa.free(source);

        var file_facts = engine.extractFacts(gpa, source, lang, target) catch |err| {
            return output.internal(stderr, "extract facts", err, exit.internal_error);
        };
        defer file_facts.deinit();

        const presenter: Presenter = .{ .stdout = stdout };
        presenter.print(file_facts) catch |err| {
            return output.internal(stderr, "print facts", err, exit.internal_error);
        };

        return exit.clean;
    }

    fn print(presenter: *const Presenter, file_facts: lint.facts.FileFacts) !void {
        const stdout = presenter.stdout;

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
};

pub const run = Presenter.run;

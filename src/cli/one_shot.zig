const std = @import("std");

const args_mod = @import("args.zig");
const exit = @import("exit.zig");
const output = @import("output.zig");
const lint = @import("engine");
const server = @import("../server.zig");

const diagnostic = lint.diagnostic;
const language = lint.language;
const daemon = server.daemon;
const protocol = server.protocol;

pub const Options = struct {
    args: []const [:0]const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    const flag_parser = args_mod.parser(&.{
        .{ .name = "lang", .kind = .arg },
        .{ .name = "filename", .kind = .arg },
    });

    pub fn prepare(arena: std.mem.Allocator, opts: Options) !Prepared {
        const parsed = flag_parser.parse(opts.args);
        if (parsed.missing != null or parsed.unknown != null or parsed.positionals().len > 0)
            return .{ .failed = try output.message(opts.stderr, usage_line, exit.usage) };

        const lang_flag = parsed.flags.lang orelse "";
        const filename = parsed.flags.filename orelse "";

        const lang = switch (language.resolve(lang_flag, filename)) {
            .ok => |n| n,
            .missing => return .{ .failed = try output.message(opts.stderr, "missing --lang (or provide --filename with a known extension)\n", exit.usage) },
            .unknown_extension => |ext| return .{ .failed = try output.format(opts.stderr, "cannot infer language from extension \"{s}\"\n", .{ext}, exit.usage) },
            .unsupported_language => |name| return .{ .failed = try output.format(opts.stderr, "lint: unsupported language: \"{s}\"\n", .{name}, exit.internal_error) },
        };

        const source = opts.stdin.allocRemaining(arena, .unlimited) catch |err|
            return .{ .failed = try output.internal(opts.stderr, "read stdin", err, exit.internal_error) };

        return .{ .ready = .{
            .language = lang.toString(),
            .filename = if (filename.len > 0) filename else null,
            .source = source,
        } };
    }

    pub fn serve(
        ctx: daemon.Context,
        arena: std.mem.Allocator,
        req: protocol.Request,
        opts: Options,
    ) !u8 {
        if (!try ctx.engine.prewarmOrReport("kata", opts.stderr)) return exit.internal_error;

        return Options.report(opts, daemon.handle(ctx, arena, req));
    }

    pub fn report(opts: Options, response: protocol.Response) !u8 {
        const rendered = response.report orelse
            return try output.format(opts.stderr, "kata: {s}\n", .{response.message orelse "lint failed"}, exit.internal_error);

        opts.writeReport(rendered) catch |err|
            return try output.internal(opts.stderr, "encode report", err, exit.internal_error);

        return if (rendered.clean) exit.clean else exit.violations;
    }

    pub fn run(
        allocator: std.mem.Allocator,
        ctx: daemon.Context,
        opts: Options,
    ) !u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        return switch (try Options.prepare(arena.allocator(), opts)) {
            .ready => |req| try Options.serve(ctx, arena.allocator(), req, opts),
            .failed => |code| code,
        };
    }

    fn writeReport(opts: Options, rendered: diagnostic.Report) !void {
        try std.json.Stringify.value(rendered, .{ .whitespace = .indent_2 }, opts.stdout);
        try opts.stdout.writeAll("\n");
        try opts.stdout.flush();
    }
};

pub const prepare = Options.prepare;
pub const serve = Options.serve;
pub const report = Options.report;
pub const run = Options.run;

const usage_line = "usage: kata --lang=<ts|tsx|go> [--filename=<path>] < source\n";

pub const Prepared = union(enum) {
    ready: protocol.Request,
    failed: u8,
};

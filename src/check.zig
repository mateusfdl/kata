const std = @import("std");

const engine_mod = @import("engine.zig");
const language = @import("language.zig");

const max_file_bytes: usize = 4 * 1024 * 1024;

pub const Outcome = enum { clean, violations };

const Counts = struct { files: usize, violations: usize };

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Outcome {
    const stat = try std.Io.Dir.cwd().statFile(io, target, .{});
    const counts = switch (stat.kind) {
        .directory => try checkDir(io, gpa, engine, target, stdout),
        .file => try checkFile(io, gpa, engine, target, stdout),
        else => return error.UnsupportedTarget,
    };

    try stdout.print("checked {d} files, {d} violations\n", .{ counts.files, counts.violations });
    try stdout.flush();
    return if (counts.violations > 0) .violations else .clean;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Counts {
    const lang = languageOf(target) orelse return error.UnsupportedTarget;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(max_file_bytes));
    defer gpa.free(source);

    return .{ .files = 1, .violations = try reportFile(gpa, engine, lang, source, target, stdout) };
}

fn checkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    target: []const u8,
    stdout: *std.Io.Writer,
) !Counts {
    var dir = try std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var counts: Counts = .{ .files = 0, .violations = 0 };
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const lang = languageOf(entry.basename) orelse continue;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(source);

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, target, "/"), entry.path });
        defer gpa.free(path);

        counts.files += 1;
        counts.violations += try reportFile(gpa, engine, lang, source, path, stdout);
    }
    return counts;
}

fn languageOf(name: []const u8) ?language.Name {
    return switch (language.resolve("", name)) {
        .ok => |n| n,
        else => null,
    };
}

fn reportFile(
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    lang: language.Name,
    source: []const u8,
    path: []const u8,
    stdout: *std.Io.Writer,
) !usize {
    const diagnostics = try engine.lint(gpa, source, lang);
    defer gpa.free(diagnostics);

    for (diagnostics) |d| {
        try stdout.print("{s}:{d}:{d} [{s}] {s}\n", .{
            path,
            d.range.start.line + 1,
            d.range.start.column + 1,
            d.rule_id,
            d.message,
        });
    }
    return diagnostics.len;
}

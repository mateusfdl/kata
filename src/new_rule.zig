const std = @import("std");

const language = @import("language.zig");

pub const exit_clean: u8 = 0;
pub const exit_usage: u8 = 64;
pub const exit_internal_error: u8 = 70;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Options = struct {
    args: []const [:0]const u8,
    user_rules_dir: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) Error!u8 {
    _ = gpa;

    if (opts.args.len != 3) {
        try opts.stderr.writeAll("usage: kata new-rule <ts|tsx|go> <rule-id>\n");
        try opts.stderr.flush();
        return exit_usage;
    }

    const lang_str = opts.args[1];
    const id = opts.args[2];

    const lang = language.Name.fromString(lang_str) orelse {
        try opts.stderr.print("unknown language: \"{s}\" (expected ts, tsx, or go)\n", .{lang_str});
        try opts.stderr.flush();
        return exit_usage;
    };

    if (!isValidId(id)) {
        try opts.stderr.print("invalid rule id: \"{s}\" (must match [A-Za-z0-9_-]+)\n", .{id});
        try opts.stderr.flush();
        return exit_usage;
    }

    const root = opts.user_rules_dir orelse {
        try opts.stderr.writeAll("cannot resolve user rules directory: set XDG_CONFIG_HOME or HOME\n");
        try opts.stderr.flush();
        return exit_usage;
    };

    const lang_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, lang.toString() });
    const file_path = try std.fmt.allocPrint(arena, "{s}/{s}.scm", .{ lang_dir, id });
    const body = try renderTemplate(arena, lang, id);

    std.Io.Dir.cwd().createDirPath(io, lang_dir) catch |err| {
        try opts.stderr.print("create directory {s}: {s}\n", .{ lang_dir, @errorName(err) });
        try opts.stderr.flush();
        return exit_internal_error;
    };

    var file = std.Io.Dir.cwd().createFile(io, file_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try opts.stderr.print("path already exists: {s}\n", .{file_path});
            try opts.stderr.flush();
            return exit_usage;
        },
        else => {
            try opts.stderr.print("create file {s}: {s}\n", .{ file_path, @errorName(err) });
            try opts.stderr.flush();
            return exit_internal_error;
        },
    };
    defer file.close(io);

    file.writeStreamingAll(io, body) catch |err| {
        try opts.stderr.print("write {s}: {s}\n", .{ file_path, @errorName(err) });
        try opts.stderr.flush();
        return exit_internal_error;
    };

    try opts.stdout.print("{s}\n", .{file_path});
    try opts.stdout.flush();
    return exit_clean;
}

fn isValidId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn renderTemplate(arena: std.mem.Allocator, lang: language.Name, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\; {s}/{s}: describe what this rule catches.
        \\; The @match capture marks the node to report; (#set! message ...) sets the diagnostic text.
        \\((identifier) @match
        \\ (#set! message "TODO: explain why this is bad"))
        \\
    , .{ lang.toString(), id });
}

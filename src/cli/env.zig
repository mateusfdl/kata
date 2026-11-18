const std = @import("std");

pub const Env = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// stdout accepts ANSI escapes. Only the pretty report reads it.
    color: bool,
};

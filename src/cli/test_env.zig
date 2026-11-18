const std = @import("std");

const Env = @import("env.zig").Env;

/// An `Env` for tests: captured stdout and stderr, fixed stdin, and an
/// environment that starts empty.
pub const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    stdin: std.Io.Reader,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    pub fn init(stdin_bytes: []const u8) TestEnv {
        const gpa = std.testing.allocator;

        return .{
            .arena = .init(gpa),
            .environ = .init(gpa),
            .stdin = .fixed(stdin_bytes),
            .out = .init(gpa),
            .err = .init(gpa),
        };
    }

    pub fn deinit(self: *TestEnv) void {
        self.out.deinit();
        self.err.deinit();
        self.environ.deinit();
        self.arena.deinit();
    }

    pub fn env(self: *TestEnv) Env {
        return .{
            .gpa = std.testing.allocator,
            .arena = self.arena.allocator(),
            .io = std.testing.io,
            .environ = &self.environ,
            .stdin = &self.stdin,
            .stdout = &self.out.writer,
            .stderr = &self.err.writer,
            .color = false,
        };
    }
};

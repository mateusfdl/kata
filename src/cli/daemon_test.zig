const std = @import("std");

const build_options = @import("build_options");

const endpoint = @import("daemon_endpoint.zig");
const daemon = @import("daemon.zig");

const TestEnv = @import("test_env.zig").TestEnv;

test "daemon: the socket path carries the version and the binary mtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try endpoint.stampedSocketPath(arena.allocator(), "/run/user/1000", 42);
    const expected = try std.fmt.allocPrint(arena.allocator(), "/run/user/1000/kata-{s}-42.sock", .{build_options.version});

    try std.testing.expectEqualStrings(expected, path);
}

test "daemon: the socket path falls back to /tmp without a runtime dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try endpoint.stampedSocketPath(arena.allocator(), null, 42);
    const expected = try std.fmt.allocPrint(arena.allocator(), "/tmp/kata-{s}-42.sock", .{build_options.version});

    try std.testing.expectEqualStrings(expected, path);
}

test "daemon: KATA_SOCKET overrides the stamped socket path" {
    var t: TestEnv = .init("");
    defer t.deinit();
    try t.environ.put("KATA_SOCKET", "/custom/kata.sock");
    try t.environ.put("XDG_RUNTIME_DIR", "/run/user/1000");

    try std.testing.expectEqualStrings("/custom/kata.sock", try endpoint.socketPath(t.env()));
}

test "daemon: grammar accepts both forms of --root" {
    try std.testing.expectEqualDeep(
        daemon.grammar.Result{ .ok = .{ .root = "src" } },
        daemon.grammar.parse(&.{ "--root", "src" }),
    );
    try std.testing.expectEqualDeep(
        daemon.grammar.Result{ .ok = .{ .root = "src" } },
        daemon.grammar.parse(&.{"--root=src"}),
    );
    try std.testing.expectEqualDeep(daemon.grammar.Result{ .ok = .{} }, daemon.grammar.parse(&.{}));
}

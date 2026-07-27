const std = @import("std");

const process = @import("process.zig");
const test_fixture = @import("../test_fixture.zig");

test "process: spawnDetached runs the command without waiting for it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    const command = try std.fmt.allocPrint(gpa, "touch {s}/spawned", .{dir});
    defer gpa.free(command);

    process.spawnDetached(io, &.{ "/bin/sh", "-c", command });

    var waited: usize = 0;
    while (waited < 200) : (waited += 1) {
        if (tmp.dir.statFile(io, "spawned", .{})) |_| break else |_| {}
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    _ = try tmp.dir.statFile(io, "spawned", .{});
}

test "process: spawnDetached swallows a missing executable" {
    process.spawnDetached(std.testing.io, &.{"/nonexistent/kata-does-not-exist"});
}

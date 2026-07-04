const std = @import("std");

const discover = @import("discover.zig");
const test_fixture = @import("../test_fixture.zig");

const Setup = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(io: std.Io) !*Setup {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Setup);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(gpa),
            .root = undefined,
        };
        _ = io;
        var rel_buf: [256]u8 = undefined;
        const rel = try test_fixture.relativeTmpPath(&rel_buf, &self.tmp.sub_path);
        self.root = try self.arena.allocator().dupe(u8, rel);
        return self;
    }

    fn deinit(self: *Setup) void {
        const gpa = std.testing.allocator;
        self.tmp.cleanup();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn path(self: *Setup, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.root, sub });
    }

    fn absolute(self: *Setup, io: std.Io, sub: []const u8) ![]const u8 {
        const cwd = try std.process.currentPathAlloc(io, self.arena.allocator());
        if (sub.len == 0) return std.fs.path.resolve(self.arena.allocator(), &.{ cwd, self.root });
        const rel = try self.path(sub);
        return std.fs.path.resolve(self.arena.allocator(), &.{ cwd, rel });
    }
};

test "discover: finds root from a file nested below .kata" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules");
    try s.tmp.dir.createDirPath(io, "proj/internal/scanner");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/internal/scanner/main.go", .data = "package scanner\n" });

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("proj/internal/scanner/main.go"));
    try std.testing.expectEqualStrings(try s.absolute(io, "proj"), found.?);
}

test "discover: anchor directory containing .kata is its own root" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("proj"));
    try std.testing.expectEqualStrings(try s.absolute(io, "proj"), found.?);
}

test "discover: nearest .kata wins over an outer project" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "outer/.kata");
    try s.tmp.dir.createDirPath(io, "outer/inner/.kata");
    try s.tmp.dir.createDirPath(io, "outer/inner/pkg");

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("outer/inner/pkg"));
    try std.testing.expectEqualStrings(try s.absolute(io, "outer/inner"), found.?);
}

test "discover: nonexistent anchor resolves from its parent directory" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata");
    try s.tmp.dir.createDirPath(io, "proj/pkg");

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("proj/pkg/new_file.go"));
    try std.testing.expectEqualStrings(try s.absolute(io, "proj"), found.?);
}

test "discover: anchor inside the .kata directory itself finds the root" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "proj/.kata/rules/go");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "proj/.kata/rules/go/no-panic.scm", .data = "((x) @match)\n" });

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("proj/.kata/rules/go/no-panic.scm"));
    try std.testing.expectEqualStrings(try s.absolute(io, "proj"), found.?);
}

test "discover: a plain file named .kata is not a project marker" {
    const io = std.testing.io;
    var s = try Setup.init(io);
    defer s.deinit();

    try s.tmp.dir.createDirPath(io, "outer/.kata");
    try s.tmp.dir.createDirPath(io, "outer/proj/pkg");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "outer/proj/.kata", .data = "not a directory\n" });

    const found = try discover.findProjectRoot(io, s.arena.allocator(), try s.path("outer/proj/pkg"));
    try std.testing.expectEqualStrings(try s.absolute(io, "outer"), found.?);
}

test "discover: no .kata up to the filesystem root returns null" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const found = try discover.findProjectRoot(io, arena.allocator(), "/kata-discover-test-absent/pkg/main.go");
    try std.testing.expectEqual(@as(?[]const u8, null), found);
}

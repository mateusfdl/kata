const std = @import("std");

const rules = @import("rules.zig");
const test_fixture = @import("../test_fixture.zig");

fn tmpPath(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    var path_buf: [256]u8 = undefined;
    const dir = try test_fixture.relativeTmpPath(&path_buf, &tmp.sub_path);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, sub });
}

test "rules: isFixturePath flags a tests file beside a kata rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ts+tsx/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/no-nested-ternary.kata", .data = "rule no-nested-ternary {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/tests/no-nested-ternary.ts", .data = "const x = 1;\n" });

    const path = try tmpPath(gpa, &tmp, "ts+tsx/tests/no-nested-ternary.ts");
    defer gpa.free(path);

    try std.testing.expect(try rules.isFixturePath(io, path));
}

test "rules: isFixturePath ignores a tests file without a sibling kata rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/tests/user.ts", .data = "const x = 1;\n" });

    const path = try tmpPath(gpa, &tmp, "src/tests/user.ts");
    defer gpa.free(path);

    try std.testing.expect(!try rules.isFixturePath(io, path));
}

test "rules: isFixturePath ignores files outside a tests directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ts+tsx");
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/no-nested-ternary.kata", .data = "rule no-nested-ternary {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ts+tsx/plain.ts", .data = "const x = 1;\n" });

    const path = try tmpPath(gpa, &tmp, "ts+tsx/plain.ts");
    defer gpa.free(path);

    try std.testing.expect(!try rules.isFixturePath(io, path));
}

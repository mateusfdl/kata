const std = @import("std");

const new_rule = @import("new_rule.zig");

fn relativeTmpPath(buf: []u8, sub_path: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{sub_path});
}

const Captured = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runOnce(
    arena: std.mem.Allocator,
    user_rules_dir: ?[]const u8,
    args: []const [:0]const u8,
) !Captured {
    var stdout_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer stdout_buf.deinit();
    var stderr_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer stderr_buf.deinit();

    const code = try new_rule.run(std.testing.allocator, arena, std.testing.io, .{
        .args = args,
        .user_rules_dir = user_rules_dir,
        .stdout = &stdout_buf.writer,
        .stderr = &stderr_buf.writer,
    });

    return .{
        .code = code,
        .stdout = try stdout_buf.toOwnedSlice(),
        .stderr = try stderr_buf.toOwnedSlice(),
    };
}

test "new-rule: writes the .scm template at the expected path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [256]u8 = undefined;
    const rules_dir = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var captured = try runOnce(arena.allocator(), rules_dir, &.{ "new-rule", "ts", "no-throw-literal" });
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, new_rule.exit_clean), captured.code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stdout, "ts/no-throw-literal.scm") != null);

    const body = try tmp.dir.readFileAlloc(
        std.testing.io,
        "ts/no-throw-literal.scm",
        std.testing.allocator,
        .limited(8 * 1024),
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "ts/no-throw-literal:") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@match") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "#set! message") != null);
}

test "new-rule: refuses to overwrite an existing rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [256]u8 = undefined;
    const rules_dir = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var first = try runOnce(arena.allocator(), rules_dir, &.{ "new-rule", "ts", "no-throw-literal" });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, new_rule.exit_clean), first.code);

    const original = try tmp.dir.readFileAlloc(
        std.testing.io,
        "ts/no-throw-literal.scm",
        std.testing.allocator,
        .limited(8 * 1024),
    );
    defer std.testing.allocator.free(original);

    var second = try runOnce(arena.allocator(), rules_dir, &.{ "new-rule", "ts", "no-throw-literal" });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, new_rule.exit_usage), second.code);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "path already exists") != null);

    const after = try tmp.dir.readFileAlloc(
        std.testing.io,
        "ts/no-throw-literal.scm",
        std.testing.allocator,
        .limited(8 * 1024),
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "new-rule: rejects unknown languages without writing a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [256]u8 = undefined;
    const rules_dir = try relativeTmpPath(&path_buf, &tmp.sub_path);

    var captured = try runOnce(arena.allocator(), rules_dir, &.{ "new-rule", "rust", "no-unsafe" });
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, new_rule.exit_usage), captured.code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr, "unknown language") != null);

    const opened = tmp.dir.openDir(std.testing.io, "rust", .{});
    try std.testing.expectError(error.FileNotFound, opened);
}

test "new-rule: rejects invalid rule ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var captured = try runOnce(arena.allocator(), "/tmp/unused", &.{ "new-rule", "ts", "no.dots" });
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, new_rule.exit_usage), captured.code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr, "invalid rule id") != null);
}

test "new-rule: requires three positional args" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var captured = try runOnce(arena.allocator(), "/tmp/unused", &.{ "new-rule", "ts" });
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, new_rule.exit_usage), captured.code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr, "usage:") != null);
}

test "new-rule: fails clearly when no user rules dir is resolvable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var captured = try runOnce(arena.allocator(), null, &.{ "new-rule", "ts", "no-foo" });
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, new_rule.exit_usage), captured.code);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr, "XDG_CONFIG_HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured.stderr, "HOME") != null);
}

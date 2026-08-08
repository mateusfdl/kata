const std = @import("std");

pub fn normalizeRelative(
    allocator: std.mem.Allocator,
    base: []const u8,
    relative: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    std.debug.assert(relative.len == 0 or relative[0] != '/');

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    if (!try apply(&stack, allocator, base)) return null;
    if (!try apply(&stack, allocator, relative)) return null;

    const joined = try std.mem.join(allocator, "/", stack.items);
    if (base.len == 0 or base[0] != '/') return joined;
    defer allocator.free(joined);
    return try std.fmt.allocPrint(allocator, "/{s}", .{joined});
}

pub fn resolveRelativeToFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    relative: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |separator|
        if (separator == 0) file_path[0..1] else file_path[0..separator]
    else
        "";
    return normalizeRelative(allocator, base, relative);
}

fn apply(
    stack: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error!bool {
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (stack.pop() == null) return false;
            continue;
        }
        try stack.append(allocator, segment);
    }
    return true;
}

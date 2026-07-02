const std = @import("std");

pub fn fileExtension(filename: []const u8) []const u8 {
    return std.fs.path.extension(filename);
}

pub fn parentDir(file_path: []const u8) []const u8 {
    return std.fs.path.dirname(file_path) orelse "";
}

pub fn join(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

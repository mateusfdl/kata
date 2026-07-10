const std = @import("std");

const file = @import("file.zig");
const paths = @import("path");

pub const max_config_bytes: usize = 64 * 1024;

pub fn resolveBase(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg|
        return try std.fmt.allocPrint(arena, "{s}/kata", .{xdg});
    if (environ.get("HOME")) |home|
        return try std.fmt.allocPrint(arena, "{s}/.config/kata", .{home});
    return null;
}

pub fn rulesPath(arena: std.mem.Allocator, base: []const u8) ![]const u8 {
    return paths.join(arena, base, "rules.yaml");
}

pub fn userRulesPath(arena: std.mem.Allocator, base: []const u8) ![]const u8 {
    return paths.join(arena, base, "rules");
}

pub fn readRulesYaml(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !?[]u8 {
    return file.readOptionalAlloc(io, allocator, file_path, max_config_bytes);
}

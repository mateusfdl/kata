const std = @import("std");

pub fn of(comptime entries: anytype) [entries.len][]const u8 {
    var names: [entries.len][]const u8 = undefined;

    inline for (entries, 0..) |entry, index| {
        names[index] = entry.name;
    }

    return names;
}

pub fn requireUnique(comptime kind: []const u8, comptime scope: []const u8, comptime names: []const []const u8) void {
    for (names, 0..) |name, i| {
        for (names[0..i]) |previous| {
            if (std.mem.eql(u8, previous, name)) {
                @compileError("duplicate " ++ kind ++ " '" ++ name ++ "' in " ++ scope);
            }
        }
    }
}

const std = @import("std");

pub fn normalize(allocator: std.mem.Allocator, span: []const u8) ![]const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var pending_space = false;
    for (span) |byte| {
        if (isWhitespace(byte)) {
            if (normalized.items.len > 0) pending_space = true;
            continue;
        }

        if (pending_space) {
            try normalized.append(allocator, ' ');
            pending_space = false;
        }
        try normalized.append(allocator, byte);
    }

    return normalized.toOwnedSlice(allocator);
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

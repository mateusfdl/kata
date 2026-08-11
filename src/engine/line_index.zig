const std = @import("std");

const diagnostic = @import("diagnostic.zig");

pub const Point = struct {
    row: u32,
    column: u32,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const Position = diagnostic.Position;
pub const Range = diagnostic.Range;

pub const LineIndex = struct {
    line_starts: []const u32,
    ownership: Ownership,

    const Ownership = enum {
        owned,
        borrowed,
    };

    pub fn init(gpa: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);

        try starts.append(gpa, 0);
        for (source, 0..) |byte, offset| {
            if (byte == '\n') try starts.append(gpa, @intCast(offset + 1));
        }

        return .{
            .line_starts = try starts.toOwnedSlice(gpa),
            .ownership = .owned,
        };
    }

    pub fn borrow(line_starts: []const u32) LineIndex {
        std.debug.assert(line_starts.len > 0 and line_starts[0] == 0);
        return .{ .line_starts = line_starts, .ownership = .borrowed };
    }

    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        // Borrowed indexes point into parsed AST storage. Free only arrays built
        // by init, then leave a valid empty borrowed index for repeat cleanup.
        if (self.ownership == .owned) gpa.free(self.line_starts);
        self.* = .{ .line_starts = &.{0}, .ownership = .borrowed };
    }

    pub fn release(self: *LineIndex) []const u32 {
        std.debug.assert(self.ownership == .owned);
        const line_starts = self.line_starts;
        self.* = .{ .line_starts = &.{0}, .ownership = .borrowed };
        return line_starts;
    }

    pub fn pointAt(self: LineIndex, byte: u32) Point {
        const row = self.rowForByte(byte);
        return .{ .row = row, .column = byte - self.line_starts[row] };
    }

    pub fn byteAt(self: LineIndex, source_len: usize, position: Position) usize {
        if (position.line >= self.line_starts.len) return source_len;

        const start = @min(@as(usize, self.line_starts[position.line]), source_len);
        const end = self.lineEnd(source_len, position.line, start);
        const column = @min(@as(usize, position.column), end - start);
        return start + column;
    }

    pub fn byteRange(self: LineIndex, source_len: usize, range: Range) ByteRange {
        const start = self.byteAt(source_len, range.start);
        const end = self.byteAt(source_len, range.end);
        return .{ .start = start, .end = @max(start, end) };
    }

    fn rowForByte(self: LineIndex, byte: u32) u32 {
        var low: usize = 0;
        var high = self.line_starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle] <= byte) low = middle + 1 else high = middle;
        }

        return @intCast(low - 1);
    }

    fn lineEnd(self: LineIndex, source_len: usize, line: u32, start: usize) usize {
        const next_line = @as(usize, line) + 1;
        if (next_line >= self.line_starts.len) return source_len;

        // Positions use content columns. Clamp before the newline byte so an
        // oversized column cannot cross into the next line.
        const next_start = @min(@as(usize, self.line_starts[next_line]), source_len);
        if (next_start <= start) return start;
        return next_start - 1;
    }
};

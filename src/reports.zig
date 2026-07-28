const std = @import("std");

const lint = @import("engine");

pub const Json = @import("reports/json.zig").Json;
pub const Pretty = @import("reports/pretty.zig").Pretty;
pub const Sarif = @import("reports/sarif.zig").Sarif;
pub const Text = @import("reports/text.zig").Text;

pub const Format = enum { pretty, text, json, sarif };

pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

pub fn reporter(gpa: std.mem.Allocator, format: Format, writer: *std.Io.Writer, color: bool) Reporter {
    return switch (format) {
        .pretty => .{ .pretty = .{ .writer = writer, .color = color } },
        .text => .{ .text = .{ .writer = writer } },
        .json => .{ .json = .{ .writer = writer } },
        .sarif => .{ .sarif = .{ .writer = writer, .gpa = gpa } },
    };
}

pub const RuleOverflow = struct {
    rule_id: []const u8,
    suppressed: usize,
    files: usize,
};

pub const Counts = struct {
    files: usize = 0,
    violations: usize = 0,
    warnings: usize = 0,

    pub fn add(self: *Counts, other: Counts) void {
        self.files += other.files;
        self.violations += other.violations;
        self.warnings += other.warnings;
    }
};

pub const Reporter = union(enum) {
    pretty: Pretty,
    text: Text,
    json: Json,
    sarif: Sarif,

    pub fn file(
        self: *Reporter,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) Error!void {
        switch (self.*) {
            inline else => |*r| try r.file(path, source, diagnostics),
        }
    }

    pub fn project(self: *Reporter, violations: []const lint.project_rule.Violation) Error!void {
        switch (self.*) {
            inline else => |*r| try r.project(violations),
        }
    }

    pub fn finish(self: *Reporter, counts: Counts, overflow: []const RuleOverflow) Error!void {
        switch (self.*) {
            inline else => |*r| try r.finish(counts, overflow),
        }
    }
};

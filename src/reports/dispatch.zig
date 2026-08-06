const std = @import("std");

const lint = @import("engine");
const json = @import("json.zig");
const pretty = @import("pretty.zig");
const sarif = @import("sarif.zig");
const summary = @import("summary.zig");
const text = @import("text.zig");

const Counts = summary.Counts;
const Json = json.Report;
const Pretty = pretty.Report;
const RuleOverflow = summary.RuleOverflow;
const Sarif = sarif.Report;
const Text = text.Report;

pub const Format = enum { pretty, text, json, sarif };

pub const Error = Sarif.Error;

pub const Reporter = union(enum) {
    pretty: Pretty,
    text: Text,
    json: Json,
    sarif: Sarif,

    /// The caller owns writer and must keep it alive through finish.
    /// SARIF retains copied rule IDs in gpa until finish or deinit.
    pub fn init(gpa: std.mem.Allocator, format: Format, writer: *std.Io.Writer, color: bool) Reporter {
        return switch (format) {
            .pretty => .{ .pretty = .{ .writer = writer, .color = color } },
            .text => .{ .text = .{ .writer = writer } },
            .json => .{ .json = Json.init(writer) },
            .sarif => .{ .sarif = Sarif.init(gpa, writer) },
        };
    }

    /// Release format-owned memory without writing a partial document.
    /// Only finish commits and flushes structured output.
    pub fn deinit(self: *Reporter) void {
        switch (self.*) {
            .sarif => |*report| report.deinit(),
            .pretty, .text, .json => {},
        }
    }

    pub fn file(
        self: *Reporter,
        path: []const u8,
        source: []const u8,
        diagnostics: []const lint.diagnostic.Diagnostic,
    ) Error!void {
        switch (self.*) {
            inline else => |*report| try report.file(path, source, diagnostics),
        }
    }

    pub fn project(self: *Reporter, violations: []const lint.project_rule.Violation) Error!void {
        switch (self.*) {
            inline else => |*report| try report.project(violations),
        }
    }

    /// Write final metadata, close structured documents, and flush output.
    /// Call this once after all file and project records.
    pub fn finish(self: *Reporter, counts: Counts, overflow: []const RuleOverflow) Error!void {
        switch (self.*) {
            inline else => |*report| try report.finish(counts, overflow),
        }
    }
};

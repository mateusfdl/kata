const std = @import("std");

const lint = @import("engine");

/// Diagnostics and fingerprints refer to exactly this source revision.
/// The caller's arena owns diagnostics and fingerprints; source and path are borrowed.
pub const FileDiagnostics = struct {
    path: []const u8,
    language: lint.language.Name,
    source: []const u8,
    diagnostics: []lint.diagnostic.Diagnostic,

    pub fn init(
        arena: std.mem.Allocator,
        path: []const u8,
        language: lint.language.Name,
        source: []const u8,
        diagnostics: []lint.diagnostic.Diagnostic,
    ) !FileDiagnostics {
        try lint.fingerprint.assign(arena, path, source, diagnostics);
        return .{ .path = path, .language = language, .source = source, .diagnostics = diagnostics };
    }
};

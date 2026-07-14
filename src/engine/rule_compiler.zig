const std = @import("std");

const fact_rule = @import("fact_rule.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");

pub const CompileError = std.mem.Allocator.Error || error{CompileFailed};

pub const RuleCompiler = struct {
    compileLang: *const fn (
        allocator: std.mem.Allocator,
        lang: language.Name,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) CompileError!?rule.CompiledRule,
    compileFacts: *const fn (
        allocator: std.mem.Allocator,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) CompileError![]const fact_rule.CompiledFactRule,
};

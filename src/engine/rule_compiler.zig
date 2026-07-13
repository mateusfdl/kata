const std = @import("std");

const fact_rule = @import("fact_rule.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");

pub const CompileError = std.mem.Allocator.Error || error{CompileFailed};

pub const RuleCompiler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        compileLang: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            lang: language.Name,
            raws: []const rule.RawRule,
            diag: *rule.Diagnostic,
        ) CompileError!?rule.CompiledRule,
        compileFacts: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            raws: []const rule.RawRule,
            diag: *rule.Diagnostic,
        ) CompileError![]const fact_rule.CompiledFactRule,
    };

    pub fn compileLang(
        self: RuleCompiler,
        allocator: std.mem.Allocator,
        lang: language.Name,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) CompileError!?rule.CompiledRule {
        return self.vtable.compileLang(self.ctx, allocator, lang, raws, diag);
    }

    pub fn compileFacts(
        self: RuleCompiler,
        allocator: std.mem.Allocator,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) CompileError![]const fact_rule.CompiledFactRule {
        return self.vtable.compileFacts(self.ctx, allocator, raws, diag);
    }
};

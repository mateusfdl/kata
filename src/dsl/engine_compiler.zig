const std = @import("std");

const compile = @import("compile.zig");
const fact_compile = @import("fact_compile.zig");
const fact_rule = @import("../lint/fact_rule.zig");
const language = @import("../lint/language.zig");
const rule = @import("../lint/rule.zig");
const rule_compiler = @import("../lint/rule_compiler.zig");

const CompileError = rule_compiler.CompileError;
const RuleCompiler = rule_compiler.RuleCompiler;

const vtable: RuleCompiler.VTable = .{
    .compileLang = compileLang,
    .compileFacts = compileFacts,
};

pub fn ruleCompiler() RuleCompiler {
    return .{ .ctx = undefined, .vtable = &vtable };
}

fn compileLang(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    lang: language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) CompileError!?rule.CompiledRule {
    return compile.compileRaws(allocator, lang, raws, diag) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
}

fn compileFacts(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) CompileError![]const fact_rule.CompiledFactRule {
    return fact_compile.compileRaws(allocator, raws, diag) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
}

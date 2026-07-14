const std = @import("std");

const compile = @import("compile.zig");
const fact_compile = @import("fact_compile.zig");
const fact_rule = @import("engine").fact_rule;
const language = @import("engine").language;
const rule = @import("engine").rule;
const rule_compiler = @import("engine").rule_compiler;

const CompileError = rule_compiler.CompileError;
const RuleCompiler = rule_compiler.RuleCompiler;

pub fn ruleCompiler() RuleCompiler {
    return .{ .compileLang = compileLang, .compileFacts = compileFacts };
}

fn compileLang(
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
    allocator: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) CompileError![]const fact_rule.CompiledFactRule {
    return fact_compile.compileRaws(allocator, raws, diag) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompileFailed,
    };
}

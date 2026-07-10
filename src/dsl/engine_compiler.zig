const std = @import("std");

const compile = @import("compile.zig");
const fact_compile = @import("fact_compile.zig");
const fact_rule = @import("../core.zig").fact_rule;
const language = @import("../core.zig").language;
const rule = @import("../core.zig").rule;
const rule_compiler = @import("../core.zig").rule_compiler;

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

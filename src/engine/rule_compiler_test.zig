const std = @import("std");

const Engine = @import("Engine.zig").Engine;
const fact_rule = @import("fact_rule.zig");
const language = @import("language.zig");
const rule = @import("rule.zig");
const rule_compiler = @import("rule_compiler.zig");
const RuleSet = @import("RuleSet.zig").RuleSet;

const Mode = enum { none, fail, oom };

var fake_seen: std.EnumArray(language.Name, u32) = .initFill(0);
var fake_mode: Mode = .none;

fn fakeCompiler() rule_compiler.RuleCompiler {
    return .{ .compileLang = fakeCompileLang, .compileFacts = fakeCompileFacts };
}

fn fakeCompileLang(
    allocator: std.mem.Allocator,
    lang: language.Name,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) rule_compiler.CompileError!?rule.CompiledRule {
    _ = allocator;
    _ = raws;
    fake_seen.getPtr(lang).* += 1;
    switch (fake_mode) {
        .none => return null,
        .fail => {
            diag.* = .{ .lang = lang, .rule_id = "boom-rule", .detail = "boom" };
            return error.CompileFailed;
        },
        .oom => return error.OutOfMemory,
    }
}

fn fakeCompileFacts(
    allocator: std.mem.Allocator,
    raws: []const rule.RawRule,
    diag: *rule.Diagnostic,
) rule_compiler.CompileError![]const fact_rule.CompiledFactRule {
    _ = allocator;
    _ = raws;
    _ = diag;
    return &.{};
}

test "rule_compiler: engine compiles only the linted language, lazily and once" {
    fake_seen = .initFill(0);
    fake_mode = .none;

    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &rule_set, fakeCompiler(), &.{});
    defer engine.deinit();

    const first = try engine.lint(gpa, "const x = 1;\n", .ts, null);
    defer gpa.free(first);
    const second = try engine.lint(gpa, "const y = 2;\n", .ts, null);
    defer gpa.free(second);

    try std.testing.expectEqual(@as(u32, 1), fake_seen.get(.ts));
    try std.testing.expectEqual(@as(u32, 0), fake_seen.get(.tsx));
    try std.testing.expectEqual(@as(u32, 0), fake_seen.get(.go));
}

test "rule_compiler: a populated compile diagnostic is reported, not propagated" {
    fake_seen = .initFill(0);
    fake_mode = .fail;

    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &rule_set, fakeCompiler(), &.{});
    defer engine.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const ready = try engine.prewarmOrReport("kata", &out.writer);
    try std.testing.expect(!ready);
    try std.testing.expectEqualStrings("kata: rule ts/boom-rule: boom\n", out.written());

    var retry_out: std.Io.Writer.Allocating = .init(gpa);
    defer retry_out.deinit();
    try std.testing.expectEqual(false, try engine.prewarmOrReport("kata", &retry_out.writer));
    try std.testing.expectEqual(@as(u32, 1), fake_seen.get(.ts));
}

test "rule_compiler: an empty compile diagnostic propagates the underlying error" {
    fake_seen = .initFill(0);
    fake_mode = .oom;

    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var engine = Engine.init(gpa, &rule_set, fakeCompiler(), &.{});
    defer engine.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(error.OutOfMemory, engine.prewarmOrReport("kata", &out.writer));

    fake_mode = .none;
    try std.testing.expectEqual(true, try engine.prewarmOrReport("kata", &out.writer));
    try std.testing.expectEqual(@as(u32, 2), fake_seen.get(.ts));
}

const std = @import("std");

const Engine = @import("Engine.zig").Engine;
const fact_rule = @import("../core.zig").fact_rule;
const language = @import("../core.zig").language;
const rule = @import("../core.zig").rule;
const rule_compiler = @import("../core.zig").rule_compiler;
const RuleSet = @import("RuleSet.zig").RuleSet;

const FakeCompiler = struct {
    seen: std.EnumArray(language.Name, u32) = .initFill(0),
    mode: Mode = .none,

    const Mode = enum { none, fail, oom };

    const vtable: rule_compiler.RuleCompiler.VTable = .{
        .compileLang = compileLang,
        .compileFacts = compileFacts,
    };

    fn compiler(self: *FakeCompiler) rule_compiler.RuleCompiler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn compileLang(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        lang: language.Name,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) rule_compiler.CompileError!?rule.CompiledRule {
        _ = allocator;
        _ = raws;
        const self: *FakeCompiler = @ptrCast(@alignCast(ctx));
        self.seen.getPtr(lang).* += 1;
        switch (self.mode) {
            .none => return null,
            .fail => {
                diag.* = .{ .lang = lang, .rule_id = "boom-rule", .detail = "boom" };
                return error.CompileFailed;
            },
            .oom => return error.OutOfMemory,
        }
    }

    fn compileFacts(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        raws: []const rule.RawRule,
        diag: *rule.Diagnostic,
    ) rule_compiler.CompileError![]const fact_rule.CompiledFactRule {
        _ = ctx;
        _ = allocator;
        _ = raws;
        _ = diag;
        return &.{};
    }
};

test "rule_compiler: engine compiles only the linted language, lazily and once" {
    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var fake: FakeCompiler = .{};
    var engine = Engine.init(gpa, &rule_set, fake.compiler());
    defer engine.deinit();

    const first = try engine.lint(gpa, "const x = 1;\n", .ts, null);
    defer gpa.free(first);
    const second = try engine.lint(gpa, "const y = 2;\n", .ts, null);
    defer gpa.free(second);

    try std.testing.expectEqual(@as(u32, 1), fake.seen.get(.ts));
    try std.testing.expectEqual(@as(u32, 0), fake.seen.get(.tsx));
    try std.testing.expectEqual(@as(u32, 0), fake.seen.get(.go));
}

test "rule_compiler: a populated compile diagnostic is reported, not propagated" {
    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var fake: FakeCompiler = .{ .mode = .fail };
    var engine = Engine.init(gpa, &rule_set, fake.compiler());
    defer engine.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const ready = try engine.prewarmOrReport("kata", &out.writer);
    try std.testing.expect(!ready);
    try std.testing.expectEqualStrings("kata: rule ts/boom-rule: boom\n", out.written());
}

test "rule_compiler: an empty compile diagnostic propagates the underlying error" {
    const gpa = std.testing.allocator;
    var rule_set: RuleSet = .{ .allocator = gpa };
    defer rule_set.deinit();

    var fake: FakeCompiler = .{ .mode = .oom };
    var engine = Engine.init(gpa, &rule_set, fake.compiler());
    defer engine.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(error.OutOfMemory, engine.prewarmOrReport("kata", &out.writer));
}

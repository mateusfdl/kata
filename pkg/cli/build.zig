const std = @import("std");

const Scenario = enum { commands, command_flags, leading_flags, root_collision, reserved_help };

pub fn build(b: *std.Build) void {
    const module = b.addModule("cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run CLI tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const Case = struct { scenario: Scenario, diagnostic: []const u8 };
    for ([_]Case{
        .{ .scenario = .commands, .diagnostic = "duplicate command 'check' in fixture" },
        .{ .scenario = .command_flags, .diagnostic = "duplicate flag '--json' in check" },
        .{ .scenario = .leading_flags, .diagnostic = "duplicate flag '--version' in fixture" },
        .{ .scenario = .root_collision, .diagnostic = "duplicate flag '--version' in fixture" },
        .{ .scenario = .reserved_help, .diagnostic = "duplicate flag '--help' in check" },
    }) |case| {
        const fixture = b.createModule(.{
            .root_source_file = b.path("tests/invalid_registry.zig"),
            .target = module.resolved_target,
        });
        fixture.addImport("cli", module);

        const options = b.addOptions();
        options.addOption(Scenario, "scenario", case.scenario);
        fixture.addOptions("options", options);

        const invalid = b.addObject(.{ .name = @tagName(case.scenario), .root_module = fixture });
        invalid.expect_errors = .{ .contains = case.diagnostic };
        test_step.dependOn(&invalid.step);
    }
}

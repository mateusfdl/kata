const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_module = tree_sitter_dep.module("tree_sitter");
    const ts_typescript_dep = b.dependency("tree_sitter_typescript", .{});

    const ts_typescript_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts_typescript_module.addCSourceFiles(.{
        .root = ts_typescript_dep.path("typescript/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{
            "-std=c11",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            "-Wno-unused-function",
        },
    });
    ts_typescript_module.addIncludePath(ts_typescript_dep.path("typescript/src"));
    const typescript_lib = b.addLibrary(.{
        .name = "ts_typescript",
        .linkage = .static,
        .root_module = ts_typescript_module,
    });

    const ts_tsx_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts_tsx_module.addCSourceFiles(.{
        .root = ts_typescript_dep.path("tsx/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{
            "-std=c11",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            "-Wno-unused-function",
        },
    });
    ts_tsx_module.addIncludePath(ts_typescript_dep.path("tsx/src"));
    const tsx_lib = b.addLibrary(.{
        .name = "ts_tsx",
        .linkage = .static,
        .root_module = ts_tsx_module,
    });

    const gen_exe = b.addExecutable(.{
        .name = "gen_embedded_rules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_embedded_rules.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_gen = b.addRunArtifact(gen_exe);
    run_gen.addDirectoryArg(b.path("rules"));
    const embedded_rules_zig = run_gen.addOutputFileArg("embedded_rules.zig");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("tree_sitter", tree_sitter_module);
    exe_module.addAnonymousImport("embedded_rules", .{
        .root_source_file = embedded_rules_zig,
    });

    exe_module.linkLibrary(typescript_lib);
    exe_module.linkLibrary(tsx_lib);
    const exe = b.addExecutable(.{
        .name = "kata",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("tree_sitter", tree_sitter_module);
    test_module.addAnonymousImport("embedded_rules", .{
        .root_source_file = embedded_rules_zig,
    });

    test_module.linkLibrary(typescript_lib);
    test_module.linkLibrary(tsx_lib);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run kata (pass args after --)");
    run_step.dependOn(&run_exe.step);
}

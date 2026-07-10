const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_module = tree_sitter_dep.module("tree_sitter");

    const mvzr_dep = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });
    const mvzr_module = mvzr_dep.module("mvzr");

    const ts_typescript_dep = b.dependency("tree_sitter_typescript", .{
        .target = target,
        .optimize = optimize,
    });
    const typescript_lib = ts_typescript_dep.artifact("ts_typescript");
    const tsx_lib = ts_typescript_dep.artifact("ts_tsx");

    const ts_go_dep = b.dependency("tree_sitter_go", .{
        .target = target,
        .optimize = optimize,
    });
    const go_lib = ts_go_dep.artifact("ts_go");

    const gen_dep = b.dependency("gen_embedded_rules", .{});
    const gen_exe = gen_dep.artifact("gen_embedded_rules");

    const run_gen = b.addRunArtifact(gen_exe);
    run_gen.has_side_effects = true;
    run_gen.addDirectoryArg(b.path("rules"));
    _ = run_gen.step.addDirectoryWatchInput(b.path("rules")) catch @panic("failed to watch rules directory");
    const embedded_rules_zig = run_gen.addOutputFileArg("embedded_rules.zig");

    const gen_kinds_dep = b.dependency("gen_node_kinds", .{});
    const run_gen_kinds = b.addRunArtifact(gen_kinds_dep.artifact("gen_node_kinds"));
    const node_kinds_zig = run_gen_kinds.addOutputFileArg("node_kinds.zig");
    run_gen_kinds.addArgs(&.{ "ts_family", "2" });
    run_gen_kinds.addFileArg(ts_typescript_dep.namedLazyPath("typescript_node_types"));
    run_gen_kinds.addFileArg(ts_typescript_dep.namedLazyPath("tsx_node_types"));
    run_gen_kinds.addArgs(&.{ "go", "1" });
    run_gen_kinds.addFileArg(ts_go_dep.namedLazyPath("go_node_types"));

    const strip = b.option(bool, "strip", "Strip debug info from the executable") orelse false;

    const grammar_libs: []const *std.Build.Step.Compile = &.{ typescript_lib, tsx_lib, go_lib };

    const path_module = b.createModule(.{
        .root_source_file = b.path("src/fs/path.zig"),
        .target = target,
        .optimize = optimize,
    });

    const node_kinds_module = b.createModule(.{
        .root_source_file = node_kinds_zig,
        .target = target,
        .optimize = optimize,
    });
    node_kinds_module.addImport("tree_sitter", tree_sitter_module);

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireCoreModule(core_module, path_module, tree_sitter_module, mvzr_module, node_kinds_module, grammar_libs);

    const dsl_module = b.createModule(.{
        .root_source_file = b.path("src/dsl/dsl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireDslModule(dsl_module, core_module, tree_sitter_module, mvzr_module, node_kinds_module);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    wireKataModule(exe_module, core_module, dsl_module, path_module, tree_sitter_module, mvzr_module, embedded_rules_zig, node_kinds_module);
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
    wireKataModule(test_module, core_module, dsl_module, path_module, tree_sitter_module, mvzr_module, embedded_rules_zig, node_kinds_module);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const core_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireCoreModule(core_test_module, path_module, tree_sitter_module, mvzr_module, node_kinds_module, grammar_libs);
    const core_unit_tests = b.addTest(.{
        .root_module = core_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(core_unit_tests).step);

    const dsl_test_module = b.createModule(.{
        .root_source_file = b.path("src/dsl/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireDslModule(dsl_test_module, core_module, tree_sitter_module, mvzr_module, node_kinds_module);
    const dsl_unit_tests = b.addTest(.{
        .root_module = dsl_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(dsl_unit_tests).step);

    const run_rule_tests = b.addRunArtifact(exe);
    run_rule_tests.addArg("test");
    run_rule_tests.addDirectoryArg(b.path("rules"));
    test_step.dependOn(&run_rule_tests.step);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run kata (pass args after --)");
    run_step.dependOn(&run_exe.step);
}

fn wireCoreModule(
    module: *std.Build.Module,
    path_module: *std.Build.Module,
    tree_sitter_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    node_kinds_module: *std.Build.Module,
    libs: []const *std.Build.Step.Compile,
) void {
    module.addImport("path", path_module);
    module.addImport("tree_sitter", tree_sitter_module);
    module.addImport("mvzr", mvzr_module);
    module.addImport("node_kinds", node_kinds_module);
    for (libs) |lib| module.linkLibrary(lib);
}

fn wireDslModule(
    module: *std.Build.Module,
    core_module: *std.Build.Module,
    tree_sitter_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    node_kinds_module: *std.Build.Module,
) void {
    module.addImport("core", core_module);
    module.addImport("tree_sitter", tree_sitter_module);
    module.addImport("mvzr", mvzr_module);
    module.addImport("node_kinds", node_kinds_module);
}

fn wireKataModule(
    module: *std.Build.Module,
    core_module: *std.Build.Module,
    dsl_module: *std.Build.Module,
    path_module: *std.Build.Module,
    tree_sitter_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    embedded_rules_zig: std.Build.LazyPath,
    node_kinds_module: *std.Build.Module,
) void {
    module.addImport("core", core_module);
    module.addImport("dsl", dsl_module);
    module.addImport("path", path_module);
    module.addImport("tree_sitter", tree_sitter_module);
    module.addImport("mvzr", mvzr_module);
    module.addAnonymousImport("embedded_rules", .{ .root_source_file = embedded_rules_zig });
    module.addImport("node_kinds", node_kinds_module);
}

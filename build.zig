const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_optimize = if (optimize == .ReleaseSafe) .ReleaseFast else optimize;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    const build_options_module = build_options.createModule();

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = native_optimize,
    });
    const tree_sitter_module = tree_sitter_dep.module("tree_sitter");

    const mvzr_dep = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });
    const mvzr_module = mvzr_dep.module("mvzr");

    const ts_typescript_dep = b.dependency("tree_sitter_typescript", .{
        .target = target,
        .optimize = native_optimize,
    });
    const typescript_lib = ts_typescript_dep.artifact("ts_typescript");
    const tsx_lib = ts_typescript_dep.artifact("ts_tsx");

    const ts_go_dep = b.dependency("tree_sitter_go", .{
        .target = target,
        .optimize = native_optimize,
    });
    const go_lib = ts_go_dep.artifact("ts_go");

    const ts_zig_dep = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = native_optimize,
    });
    const zig_lib = ts_zig_dep.artifact("ts_zig");

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
    run_gen_kinds.addArgs(&.{ "zig", "1" });
    run_gen_kinds.addFileArg(ts_zig_dep.namedLazyPath("zig_node_types"));

    const strip = b.option(bool, "strip", "Strip debug info from the executable") orelse false;

    const grammar_libs: []const *std.Build.Step.Compile = &.{ typescript_lib, tsx_lib, go_lib, zig_lib };

    const path_module = b.createModule(.{
        .root_source_file = b.path("src/fs/path.zig"),
        .target = target,
        .optimize = optimize,
    });

    const git_module = b.createModule(.{
        .root_source_file = b.path("src/git/git.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_module.addImport("path", path_module);

    const node_kinds_module = b.createModule(.{
        .root_source_file = node_kinds_zig,
        .target = target,
        .optimize = optimize,
    });
    node_kinds_module.addImport("tree_sitter", tree_sitter_module);

    // Zig treats separate module instances as separate type identities. Share one
    // instance so utility types can cross engine, DSL, CLI, and test boundaries.
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireEngineModule(engine_module, shared_module, path_module, tree_sitter_module, mvzr_module, node_kinds_module, grammar_libs);

    const dsl_module = b.createModule(.{
        .root_source_file = b.path("src/dsl/dsl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireDslModule(dsl_module, engine_module, shared_module, mvzr_module, node_kinds_module);

    const cli_dep = b.dependency("cli", .{ .target = target, .optimize = optimize });
    const cli_module = cli_dep.module("cli");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    exe_module.addImport("cli", cli_module);
    wireKataModule(exe_module, engine_module, dsl_module, shared_module, path_module, git_module, mvzr_module, embedded_rules_zig, node_kinds_module, build_options_module);
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
    test_module.addImport("cli", cli_module);
    wireKataModule(test_module, engine_module, dsl_module, shared_module, path_module, git_module, mvzr_module, embedded_rules_zig, node_kinds_module, build_options_module);
    // Test artifacts share one install directory. Distinct names keep each
    // debugger target addressable without replacing another test binary.
    const unit_tests = b.addTest(.{
        .name = "kata-test",
        .root_module = test_module,
        .use_llvm = true,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&cli_dep.builder.top_level_steps.get("test").?.step);

    // Project tests need this build graph for named modules and linked grammars.
    // Install stable debugger paths separately so the normal test step stays run-only.
    const test_bin_step = b.step("test-bin", "Install unit test binaries into zig-out/bin for debugging");
    test_bin_step.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    const engine_test_module = b.createModule(.{
        .root_source_file = b.path("src/engine/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireEngineModule(engine_test_module, shared_module, path_module, tree_sitter_module, mvzr_module, node_kinds_module, grammar_libs);
    const engine_unit_tests = b.addTest(.{
        .name = "engine-test",
        .root_module = engine_test_module,
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(engine_unit_tests).step);
    test_bin_step.dependOn(&b.addInstallArtifact(engine_unit_tests, .{}).step);

    const dsl_test_module = b.createModule(.{
        .root_source_file = b.path("src/dsl/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireDslModule(dsl_test_module, engine_module, shared_module, mvzr_module, node_kinds_module);
    const dsl_unit_tests = b.addTest(.{
        .name = "dsl-test",
        .root_module = dsl_test_module,
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(dsl_unit_tests).step);
    test_bin_step.dependOn(&b.addInstallArtifact(dsl_unit_tests, .{}).step);

    const shared_unit_tests = b.addTest(.{
        .name = "shared-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(shared_unit_tests).step);
    test_bin_step.dependOn(&b.addInstallArtifact(shared_unit_tests, .{}).step);

    const run_rule_tests = b.addRunArtifact(exe);
    run_rule_tests.addArg("test");
    run_rule_tests.addDirectoryArg(b.path("rules"));
    test_step.dependOn(&run_rule_tests.step);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run kata (pass args after --)");
    run_step.dependOn(&run_exe.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_module.addImport("engine", engine_module);
    bench_module.addImport("dsl", dsl_module);
    const bench_exe = b.addExecutable(.{
        .name = "kata-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run engine performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // This benchmark compares data structures rather than the caller's selected
    // build mode. Pin its complete module graph to ReleaseFast so Debug safety
    // checks cannot dominate either implementation.
    const cache_shared_module = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const cache_engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    wireEngineModule(cache_engine_module, cache_shared_module, path_module, tree_sitter_module, mvzr_module, node_kinds_module, grammar_libs);

    const cache_bench_module = b.createModule(.{
        .root_source_file = b.path("src/server/file_diagnostics_cache_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    cache_bench_module.addImport("engine", cache_engine_module);
    cache_bench_module.addImport("shared", cache_shared_module);
    const cache_bench_exe = b.addExecutable(.{
        .name = "file-diagnostics-cache-bench",
        .root_module = cache_bench_module,
    });
    const run_cache_bench = b.addRunArtifact(cache_bench_exe);
    const cache_bench_step = b.step("file-diagnostics-cache-bench", "Run file diagnostics cache benchmarks");
    cache_bench_step.dependOn(&run_cache_bench.step);
}

fn wireEngineModule(
    module: *std.Build.Module,
    shared_module: *std.Build.Module,
    path_module: *std.Build.Module,
    tree_sitter_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    node_kinds_module: *std.Build.Module,
    libs: []const *std.Build.Step.Compile,
) void {
    module.addImport("shared", shared_module);
    module.addImport("path", path_module);
    module.addImport("tree_sitter", tree_sitter_module);
    module.addImport("mvzr", mvzr_module);
    module.addImport("node_kinds", node_kinds_module);
    for (libs) |lib| module.linkLibrary(lib);
}

fn wireDslModule(
    module: *std.Build.Module,
    engine_module: *std.Build.Module,
    shared_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    node_kinds_module: *std.Build.Module,
) void {
    module.addImport("engine", engine_module);
    module.addImport("shared", shared_module);
    module.addImport("mvzr", mvzr_module);
    module.addImport("node_kinds", node_kinds_module);
}

fn wireKataModule(
    module: *std.Build.Module,
    engine_module: *std.Build.Module,
    dsl_module: *std.Build.Module,
    shared_module: *std.Build.Module,
    path_module: *std.Build.Module,
    git_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    embedded_rules_zig: std.Build.LazyPath,
    node_kinds_module: *std.Build.Module,
    build_options_module: *std.Build.Module,
) void {
    module.addImport("engine", engine_module);
    module.addImport("dsl", dsl_module);
    module.addImport("shared", shared_module);
    module.addImport("path", path_module);
    module.addImport("git", git_module);
    module.addImport("mvzr", mvzr_module);
    module.addAnonymousImport("embedded_rules", .{ .root_source_file = embedded_rules_zig });
    module.addImport("node_kinds", node_kinds_module);
    module.addImport("build_options", build_options_module);
}

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
    const ts_go_dep = b.dependency("tree_sitter_go", .{});
    const mvzr_dep = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });
    const mvzr_module = mvzr_dep.module("mvzr");

    const typescript_lib = addTreeSitterLib(b, .{
        .name = "ts_typescript",
        .target = target,
        .optimize = optimize,
        .src_root = ts_typescript_dep.path("typescript/src"),
        .files = &.{ "parser.c", "scanner.c" },
    });
    const tsx_lib = addTreeSitterLib(b, .{
        .name = "ts_tsx",
        .target = target,
        .optimize = optimize,
        .src_root = ts_typescript_dep.path("tsx/src"),
        .files = &.{ "parser.c", "scanner.c" },
    });
    const go_lib = addTreeSitterLib(b, .{
        .name = "ts_go",
        .target = target,
        .optimize = optimize,
        .src_root = ts_go_dep.path("src"),
        .files = &.{"parser.c"},
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
    _ = run_gen.step.addDirectoryWatchInput(b.path("rules")) catch @panic("failed to watch rules directory");
    const embedded_rules_zig = run_gen.addOutputFileArg("embedded_rules.zig");

    const strip = b.option(bool, "strip", "Strip debug info from the executable") orelse false;

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    wireKataModule(exe_module, tree_sitter_module, mvzr_module, embedded_rules_zig, &.{ typescript_lib, tsx_lib, go_lib });
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
    wireKataModule(test_module, tree_sitter_module, mvzr_module, embedded_rules_zig, &.{ typescript_lib, tsx_lib, go_lib });
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

fn wireKataModule(
    module: *std.Build.Module,
    tree_sitter_module: *std.Build.Module,
    mvzr_module: *std.Build.Module,
    embedded_rules_zig: std.Build.LazyPath,
    libs: []const *std.Build.Step.Compile,
) void {
    module.addImport("tree_sitter", tree_sitter_module);
    module.addImport("mvzr", mvzr_module);
    module.addAnonymousImport("embedded_rules", .{ .root_source_file = embedded_rules_zig });
    for (libs) |lib| module.linkLibrary(lib);
}

const TsLibOptions = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_root: std.Build.LazyPath,
    files: []const []const u8,
};

fn addTreeSitterLib(b: *std.Build, opts: TsLibOptions) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    module.addCSourceFiles(.{
        .root = opts.src_root,
        .files = opts.files,
        .flags = &.{
            "-std=c11",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            "-Wno-unused-function",
        },
    });
    module.addIncludePath(opts.src_root);
    return b.addLibrary(.{
        .name = opts.name,
        .linkage = .static,
        .root_module = module,
    });
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("tree_sitter_go_src", .{});

    const go = addGrammar(b, .{
        .name = "ts_go",
        .target = target,
        .optimize = optimize,
        .src_root = upstream.path("src"),
        .files = &.{"parser.c"},
    });
    b.installArtifact(go);
}

const GrammarOptions = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_root: std.Build.LazyPath,
    files: []const []const u8,
};

fn addGrammar(b: *std.Build, opts: GrammarOptions) *std.Build.Step.Compile {
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

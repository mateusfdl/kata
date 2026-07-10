const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("tree_sitter_typescript_src", .{});

    b.addNamedLazyPath("typescript_node_types", upstream.path("typescript/src/node-types.json"));
    b.addNamedLazyPath("tsx_node_types", upstream.path("tsx/src/node-types.json"));

    const typescript = addGrammar(b, .{
        .name = "ts_typescript",
        .target = target,
        .optimize = optimize,
        .src_root = upstream.path("typescript/src"),
        .files = &.{ "parser.c", "scanner.c" },
    });
    b.installArtifact(typescript);

    const tsx = addGrammar(b, .{
        .name = "ts_tsx",
        .target = target,
        .optimize = optimize,
        .src_root = upstream.path("tsx/src"),
        .files = &.{ "parser.c", "scanner.c" },
    });
    b.installArtifact(tsx);
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

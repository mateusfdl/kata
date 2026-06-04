const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "gen_embedded_rules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(exe);
}

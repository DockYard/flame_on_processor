const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module for use as a dependency by other Zig projects
    const mod = b.addModule("flame_on_processor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Tests: run all test blocks from root.zig (which re-exports all modules)
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    _ = mod;
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
}

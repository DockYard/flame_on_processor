const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module for use as a dependency by other Zig projects
    const mod = b.addModule("flame_on_processor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // NIF shared library
    const nif_mod = b.createModule(.{
        .root_source_file = b.path("src/nif.zig"),
        .target = target,
        .optimize = optimize,
    });
    nif_mod.addImport("flame_on_processor", mod);
    const nif = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "flame_on_processor_nif",
        .root_module = nif_mod,
    });
    // NIF symbols (enif_*) are provided by the BEAM VM at load time.
    // Allow undefined symbols so the linker does not fail.
    nif.linker_allow_shlib_undefined = true;

    // macOS needs -undefined dynamic_lookup for NIF shared libraries.
    if (nif.rootModuleTarget().os.tag == .macos) {
        nif.root_module.addRPathSpecial("@loader_path");
    }
    b.installArtifact(nif);

    // Tests: run all test blocks from root.zig (which re-exports all modules)
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
}

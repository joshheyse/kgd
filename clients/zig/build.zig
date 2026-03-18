const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (importable by downstream projects).
    const kgd_mod = b.addModule("kgd", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact.
    const lib = b.addStaticLibrary(.{
        .name = "kgd",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // ---------- Tests ----------

    // Unit tests in src/protocol.zig
    const protocol_tests = b.addTest(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests in src/client.zig
    const client_tests = b.addTest(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Integration tests in test/client_test.zig
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/client_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("kgd", kgd_mod);

    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ZActor library
    const zactor = b.addStaticLibrary(.{
        .name = "zactor",
        .root_source_file = b.path("src/zactor.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(zactor);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/zactor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

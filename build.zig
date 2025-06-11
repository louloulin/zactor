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

    // Create a module for zactor
    const zactor_module = b.addModule("zactor", .{
        .root_source_file = b.path("src/zactor.zig"),
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

    // Supervisor tests
    const supervisor_tests = b.addTest(.{
        .root_source_file = b.path("tests/supervisor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    supervisor_tests.root_module.addImport("zactor", zactor_module);

    const run_supervisor_tests = b.addRunArtifact(supervisor_tests);
    const supervisor_test_step = b.step("test-supervisor", "Run supervisor tests");
    supervisor_test_step.dependOn(&run_supervisor_tests.step);

    // Simple supervisor tests
    const simple_supervisor_tests = b.addTest(.{
        .root_source_file = b.path("tests/simple_supervisor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_supervisor_tests.root_module.addImport("zactor", zactor_module);

    const run_simple_supervisor_tests = b.addRunArtifact(simple_supervisor_tests);
    const simple_supervisor_test_step = b.step("test-simple-supervisor", "Run simple supervisor tests");
    simple_supervisor_test_step.dependOn(&run_simple_supervisor_tests.step);

    // Examples
    const basic_example = b.addExecutable(.{
        .name = "basic_example",
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    basic_example.root_module.addImport("zactor", zactor_module);

    const ping_pong_example = b.addExecutable(.{
        .name = "ping_pong_example",
        .root_source_file = b.path("examples/ping_pong.zig"),
        .target = target,
        .optimize = optimize,
    });
    ping_pong_example.root_module.addImport("zactor", zactor_module);

    const supervisor_example = b.addExecutable(.{
        .name = "supervisor_example",
        .root_source_file = b.path("examples/supervisor_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    supervisor_example.root_module.addImport("zactor", zactor_module);

    const simple_supervisor = b.addExecutable(.{
        .name = "simple_supervisor",
        .root_source_file = b.path("examples/simple_supervisor.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_supervisor.root_module.addImport("zactor", zactor_module);

    // Install examples
    b.installArtifact(basic_example);
    b.installArtifact(ping_pong_example);
    b.installArtifact(supervisor_example);
    b.installArtifact(simple_supervisor);

    // Run steps for examples
    const run_basic = b.addRunArtifact(basic_example);
    const run_ping_pong = b.addRunArtifact(ping_pong_example);
    const run_supervisor = b.addRunArtifact(supervisor_example);
    const run_simple_supervisor = b.addRunArtifact(simple_supervisor);

    const basic_step = b.step("run-basic", "Run basic example");
    basic_step.dependOn(&run_basic.step);

    const ping_pong_step = b.step("run-ping-pong", "Run ping-pong example");
    ping_pong_step.dependOn(&run_ping_pong.step);

    const supervisor_step = b.step("run-supervisor", "Run supervisor example");
    supervisor_step.dependOn(&run_supervisor.step);

    const simple_supervisor_step = b.step("run-simple-supervisor", "Run simple supervisor example");
    simple_supervisor_step.dependOn(&run_simple_supervisor.step);

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark.root_module.addImport("zactor", zactor_module);

    b.installArtifact(benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Add debug message flow test
    const debug_flow = b.addExecutable(.{
        .name = "debug_message_flow",
        .root_source_file = b.path("debug_message_flow.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_flow.root_module.addImport("zactor", zactor_module);
    b.installArtifact(debug_flow);

    const run_debug_flow = b.addRunArtifact(debug_flow);
    const debug_flow_step = b.step("debug-flow", "Run debug message flow test");
    debug_flow_step.dependOn(&run_debug_flow.step);
}

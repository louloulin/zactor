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

    // High performance tests
    const high_performance_tests = b.addTest(.{
        .root_source_file = b.path("tests/high_performance_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    high_performance_tests.root_module.addImport("zactor", zactor_module);

    const run_high_performance_tests = b.addRunArtifact(high_performance_tests);
    const high_performance_test_step = b.step("test-high-performance", "Run high performance tests");
    high_performance_test_step.dependOn(&run_high_performance_tests.step);

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

    // 压力测试
    const stress_test = b.addExecutable(.{
        .name = "stress_test",
        .root_source_file = b.path("examples/stress_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_test.root_module.addImport("zactor", zactor_module);

    // Ring Buffer基准测试
    const ring_buffer_benchmark = b.addExecutable(.{
        .name = "ring_buffer_benchmark",
        .root_source_file = b.path("examples/ring_buffer_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    ring_buffer_benchmark.root_module.addImport("zactor", zactor_module);

    // 简单Ring Buffer测试
    const simple_ring_buffer_test = b.addExecutable(.{
        .name = "simple_ring_buffer_test",
        .root_source_file = b.path("examples/simple_ring_buffer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_ring_buffer_test.root_module.addImport("zactor", zactor_module);

    // 高性能基准测试
    const high_performance_benchmark = b.addExecutable(.{
        .name = "high_performance_benchmark",
        .root_source_file = b.path("examples/high_performance_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    high_performance_benchmark.root_module.addImport("zactor", zactor_module);

    // Install examples
    b.installArtifact(basic_example);
    b.installArtifact(ping_pong_example);
    b.installArtifact(supervisor_example);
    b.installArtifact(simple_supervisor);
    b.installArtifact(stress_test);
    b.installArtifact(ring_buffer_benchmark);
    b.installArtifact(simple_ring_buffer_test);
    b.installArtifact(high_performance_benchmark);

    // Run steps for examples
    const run_basic = b.addRunArtifact(basic_example);
    const run_ping_pong = b.addRunArtifact(ping_pong_example);
    const run_supervisor = b.addRunArtifact(supervisor_example);
    const run_simple_supervisor = b.addRunArtifact(simple_supervisor);
    const run_stress_test = b.addRunArtifact(stress_test);
    const run_ring_buffer_benchmark = b.addRunArtifact(ring_buffer_benchmark);
    const run_simple_ring_buffer_test = b.addRunArtifact(simple_ring_buffer_test);
    const run_high_performance_benchmark = b.addRunArtifact(high_performance_benchmark);

    const basic_step = b.step("run-basic", "Run basic example");
    basic_step.dependOn(&run_basic.step);

    const ping_pong_step = b.step("run-ping-pong", "Run ping-pong example");
    ping_pong_step.dependOn(&run_ping_pong.step);

    const supervisor_step = b.step("run-supervisor", "Run supervisor example");
    supervisor_step.dependOn(&run_supervisor.step);

    const simple_supervisor_step = b.step("run-simple-supervisor", "Run simple supervisor example");
    simple_supervisor_step.dependOn(&run_simple_supervisor.step);

    const stress_test_step = b.step("stress-test", "Run high-performance stress test");
    stress_test_step.dependOn(&run_stress_test.step);

    const ring_buffer_benchmark_step = b.step("ring-buffer-benchmark", "Run Ring Buffer performance benchmark");
    ring_buffer_benchmark_step.dependOn(&run_ring_buffer_benchmark.step);

    const simple_ring_buffer_test_step = b.step("simple-ring-buffer-test", "Run simple Ring Buffer test");
    simple_ring_buffer_test_step.dependOn(&run_simple_ring_buffer_test.step);

    const high_performance_benchmark_step = b.step("high-perf-benchmark", "Run high performance benchmark");
    high_performance_benchmark_step.dependOn(&run_high_performance_benchmark.step);

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark.root_module.addImport("zactor", zactor_module);

    // Performance benchmark
    const performance_benchmark = b.addExecutable(.{
        .name = "performance_benchmark",
        .root_source_file = b.path("benchmarks/performance_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    performance_benchmark.root_module.addImport("zactor", zactor_module);

    b.installArtifact(benchmark);
    b.installArtifact(performance_benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    const run_performance_benchmark = b.addRunArtifact(performance_benchmark);

    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    const perf_benchmark_step = b.step("perf-benchmark", "Run detailed performance benchmarks");
    perf_benchmark_step.dependOn(&run_performance_benchmark.step);
}

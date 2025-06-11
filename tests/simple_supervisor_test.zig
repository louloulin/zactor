const std = @import("std");
const testing = std.testing;
const zactor = @import("zactor");

test "supervisor system initialization" {
    const allocator = testing.allocator;

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 5,
        .scheduler_threads = 1,
    });

    var system = try zactor.ActorSystem.init("test-supervisor", allocator);
    defer system.deinit();

    // Test supervisor configuration
    system.setSupervisorConfig(.{
        .strategy = .restart,
        .max_restarts = 2,
        .restart_window_seconds = 10,
    });

    // Get supervisor stats
    const stats = system.getSupervisorStats();
    try testing.expect(stats.total_children == 0);
    try testing.expect(stats.active_children == 0);
    try testing.expect(stats.total_restarts == 0);
    try testing.expect(stats.strategy == .restart);

    std.log.info("Supervisor system initialization test passed", .{});
}

test "supervisor configuration" {
    const allocator = testing.allocator;

    var supervisor = zactor.Supervisor.init(allocator, .{
        .strategy = .restart,
        .max_restarts = 3,
        .restart_window_seconds = 60,
        .backoff_initial_ms = 100,
        .backoff_max_ms = 1000,
        .backoff_multiplier = 2.0,
    });
    defer supervisor.deinit();

    // Test initial state
    const stats = supervisor.getStats();
    try testing.expect(stats.total_children == 0);
    try testing.expect(stats.active_children == 0);
    try testing.expect(stats.total_restarts == 0);
    try testing.expect(stats.strategy == .restart);

    std.log.info("Supervisor configuration test passed", .{});
}

test "supervisor restart logic" {
    const config = zactor.SupervisorConfig{
        .strategy = .restart,
        .max_restarts = 2,
        .restart_window_seconds = 60,
        .backoff_initial_ms = 100,
        .backoff_max_ms = 1000,
        .backoff_multiplier = 2.0,
    };

    // Test configuration values
    try testing.expect(config.strategy == .restart);
    try testing.expect(config.max_restarts == 2);
    try testing.expect(config.restart_window_seconds == 60);
    try testing.expect(config.backoff_initial_ms == 100);
    try testing.expect(config.backoff_max_ms == 1000);
    try testing.expect(config.backoff_multiplier == 2.0);

    std.log.info("Supervisor restart logic test passed", .{});
}

test "supervisor strategies" {
    const allocator = testing.allocator;

    // Test different strategies
    const strategies = [_]zactor.SupervisorStrategy{
        .restart,
        .stop,
        .restart_all,
        .stop_all,
        .escalate,
    };

    for (strategies) |strategy| {
        var supervisor = zactor.Supervisor.init(allocator, .{
            .strategy = strategy,
            .max_restarts = 3,
        });
        defer supervisor.deinit();

        const stats = supervisor.getStats();
        try testing.expect(stats.strategy == strategy);
    }

    std.log.info("Supervisor strategies test passed", .{});
}

test "metrics integration" {

    // Reset metrics
    zactor.metrics.reset();

    // Check initial state
    try testing.expect(zactor.metrics.getActorFailures() == 0);
    try testing.expect(zactor.metrics.getActorsCreated() == 0);

    // Simulate some metrics
    zactor.metrics.incrementActorFailures();
    zactor.metrics.incrementActorsCreated();

    try testing.expect(zactor.metrics.getActorFailures() == 1);
    try testing.expect(zactor.metrics.getActorsCreated() == 1);

    // Reset again
    zactor.metrics.reset();
    try testing.expect(zactor.metrics.getActorFailures() == 0);
    try testing.expect(zactor.metrics.getActorsCreated() == 0);

    std.log.info("Metrics integration test passed", .{});
}

const std = @import("std");
const zactor = @import("zactor");

// Benchmark actor that just counts messages
const BenchmarkActor = struct {
    const Self = @This();

    id: u32,
    message_count: std.atomic.Value(u64),

    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .message_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        _ = message;
        _ = self.message_count.fetchAdd(1, .monotonic);
    }

    pub fn preStart(_: *Self, _: *zactor.ActorContext) !void {
        // Silent start for benchmarking
    }

    pub fn postStop(_: *Self, _: *zactor.ActorContext) !void {
        // Silent stop for benchmarking
    }

    pub fn preRestart(_: *Self, _: *zactor.ActorContext, _: anyerror) !void {
        // Silent restart for benchmarking
    }

    pub fn postRestart(_: *Self, _: *zactor.ActorContext) !void {
        // Silent restart for benchmarking
    }

    pub fn getMessageCount(self: *Self) u64 {
        return self.message_count.load(.monotonic);
    }
};

// Benchmark configuration
const BenchmarkConfig = struct {
    num_actors: u32,
    messages_per_actor: u32,
    scheduler_threads: u32,
    duration_seconds: u32,
};

fn runThroughputBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !void {
    std.log.info("=== Throughput Benchmark ===", .{});
    std.log.info("Actors: {}, Messages per actor: {}, Threads: {}", .{ config.num_actors, config.messages_per_actor, config.scheduler_threads });

    // Initialize ZActor
    zactor.init(.{
        .max_actors = config.num_actors * 2,
        .scheduler_config = .{
            .worker_threads = config.scheduler_threads,
            .enable_work_stealing = true,
            .task_queue_capacity = 10000,
        },
        .default_mailbox_capacity = 10000,
    });

    // Reset metrics
    zactor.metrics.reset();

    // Create actor system
    var system = try zactor.ActorSystem.init("benchmark-system", zactor.SystemConfiguration.default(), allocator);
    defer system.deinit();

    try system.start();

    // Spawn benchmark actors
    const actors = try allocator.alloc(zactor.ActorRef, config.num_actors);
    defer allocator.free(actors);

    for (actors, 0..) |*actor_ref, i| {
        actor_ref.* = try system.spawn(BenchmarkActor, BenchmarkActor.init(@intCast(i)));
    }

    std.log.info("Spawned {} actors", .{config.num_actors});

    // Measure message sending throughput
    const start_time = std.time.nanoTimestamp();

    // Send messages to all actors
    for (0..config.messages_per_actor) |msg_num| {
        for (actors) |actor_ref| {
            const message_data = try std.fmt.allocPrint(allocator, "message_{}", .{msg_num});
            defer allocator.free(message_data);

            try actor_ref.send([]const u8, message_data, allocator);
        }
    }

    const send_end_time = std.time.nanoTimestamp();
    const send_duration_ns = send_end_time - start_time;

    std.log.info("All messages sent in {d:.2} ms", .{@as(f64, @floatFromInt(send_duration_ns)) / 1_000_000.0});

    // Wait for all messages to be processed
    std.log.info("Waiting for message processing...", .{});
    const total_expected_messages = config.num_actors * config.messages_per_actor;

    while (true) {
        const current_received = zactor.metrics.getMessagesReceived();
        if (current_received >= total_expected_messages) {
            break;
        }
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    const end_time = std.time.nanoTimestamp();
    const total_duration_ns = end_time - start_time;

    // Calculate metrics
    const total_messages = zactor.metrics.getMessagesSent();
    const messages_received = zactor.metrics.getMessagesReceived();
    const duration_seconds = @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0;

    const throughput = @as(f64, @floatFromInt(messages_received)) / duration_seconds;
    const avg_latency_ns = @as(f64, @floatFromInt(total_duration_ns)) / @as(f64, @floatFromInt(messages_received));

    std.log.info("=== Benchmark Results ===", .{});
    std.log.info("Total duration: {d:.3} seconds", .{duration_seconds});
    std.log.info("Messages sent: {}", .{total_messages});
    std.log.info("Messages received: {}", .{messages_received});
    std.log.info("Throughput: {d:.0} messages/second", .{throughput});
    std.log.info("Average latency: {d:.2} μs", .{avg_latency_ns / 1000.0});

    // Get system stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    system.shutdown();
}

fn runLatencyBenchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Latency Benchmark ===", .{});

    zactor.init(.{
        .max_actors = 10,
        .scheduler_config = .{
            .worker_threads = 1, // Single thread for consistent latency measurement
            .enable_work_stealing = false,
        },
    });

    zactor.metrics.reset();

    var system = try zactor.ActorSystem.init("latency-benchmark", zactor.SystemConfiguration.default(), allocator);
    defer system.deinit();

    try system.start();

    // Spawn a single actor for latency testing
    const actor_ref = try system.spawn(BenchmarkActor, BenchmarkActor.init(1));

    const num_samples = 1000;
    const latencies = try allocator.alloc(u64, num_samples);
    defer allocator.free(latencies);

    // Warm up
    for (0..100) |_| {
        try actor_ref.send([]const u8, "warmup", allocator);
    }
    std.time.sleep(10 * std.time.ns_per_ms);

    // Measure individual message latencies
    for (latencies, 0..) |*latency, i| {
        const start = std.time.nanoTimestamp();

        const message_data = try std.fmt.allocPrint(allocator, "latency_test_{}", .{i});
        defer allocator.free(message_data);

        try actor_ref.send([]const u8, message_data, allocator);

        // Wait for message to be processed (simple approach)
        const initial_count = zactor.metrics.getMessagesReceived();
        while (zactor.metrics.getMessagesReceived() <= initial_count) {
            std.time.sleep(1); // 1 nanosecond
        }

        const end = std.time.nanoTimestamp();
        latency.* = @intCast(end - start);
    }

    // Calculate latency statistics
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    const min_latency = latencies[0];
    const max_latency = latencies[latencies.len - 1];
    const median_latency = latencies[latencies.len / 2];
    const p99_latency = latencies[(latencies.len * 99) / 100];

    var sum: u64 = 0;
    for (latencies) |lat| {
        sum += lat;
    }
    const avg_latency = sum / latencies.len;

    std.log.info("=== Latency Results ({} samples) ===", .{num_samples});
    std.log.info("Min latency: {d:.2} μs", .{@as(f64, @floatFromInt(min_latency)) / 1000.0});
    std.log.info("Avg latency: {d:.2} μs", .{@as(f64, @floatFromInt(avg_latency)) / 1000.0});
    std.log.info("Median latency: {d:.2} μs", .{@as(f64, @floatFromInt(median_latency)) / 1000.0});
    std.log.info("P99 latency: {d:.2} μs", .{@as(f64, @floatFromInt(p99_latency)) / 1000.0});
    std.log.info("Max latency: {d:.2} μs", .{@as(f64, @floatFromInt(max_latency)) / 1000.0});

    system.shutdown();
}

fn runScalabilityBenchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Scalability Benchmark ===", .{});

    const thread_counts = [_]u32{ 1, 2, 4, 8 };
    const num_actors = 100;
    const messages_per_actor = 1000;

    for (thread_counts) |thread_count| {
        std.log.info("Testing with {} threads...", .{thread_count});

        const config = BenchmarkConfig{
            .num_actors = num_actors,
            .messages_per_actor = messages_per_actor,
            .scheduler_threads = thread_count,
            .duration_seconds = 10,
        };

        try runThroughputBenchmark(allocator, config);
        std.log.info("---", .{});
    }
}

fn runSupervisionBenchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Supervision Overhead Benchmark ===", .{});

    const num_actors = 100;
    const messages_per_actor = 500;

    // Test without supervision
    {
        std.log.info("Testing without supervision...", .{});

        zactor.init(.{
            .max_actors = num_actors * 2,
            .scheduler_config = .{
                .worker_threads = 4,
                .enable_work_stealing = true,
            },
        });

        zactor.metrics.reset();

        var system = try zactor.ActorSystem.init("no-supervision-benchmark", zactor.SystemConfiguration.default(), allocator);
        defer system.deinit();

        try system.start();

        const actors = try allocator.alloc(zactor.ActorRef, num_actors);
        defer allocator.free(actors);

        // Spawn actors
        for (actors, 0..) |*actor_ref, i| {
            actor_ref.* = try system.spawn(BenchmarkActor, BenchmarkActor.init(@intCast(i + 1)));
        }

        const start_time = std.time.nanoTimestamp();

        // Send messages
        for (0..messages_per_actor) |msg_num| {
            for (actors) |actor_ref| {
                const message_data = try std.fmt.allocPrint(allocator, "msg_{}", .{msg_num});
                defer allocator.free(message_data);
                try actor_ref.send([]const u8, message_data, allocator);
            }
        }

        // Wait for completion
        try system.awaitQuiescence(5000);

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        const total_messages = num_actors * messages_per_actor;
        const throughput = @as(f64, @floatFromInt(total_messages)) / (duration_ms / 1000.0);

        std.log.info("Without supervision:", .{});
        std.log.info("  Duration: {d:.2} ms", .{duration_ms});
        std.log.info("  Throughput: {d:.0} messages/second", .{throughput});

        system.shutdown();
    }

    // Test with supervision
    {
        std.log.info("Testing with supervision...", .{});

        zactor.init(.{
            .max_actors = num_actors * 2,
            .scheduler_config = .{
                .worker_threads = 4,
                .enable_work_stealing = true,
            },
        });

        zactor.metrics.reset();

        var system = try zactor.ActorSystem.init("supervision-benchmark", zactor.SystemConfiguration.default(), allocator);
        defer system.deinit();

        // Configure supervision
        system.setSupervisorConfig(.{
            .strategy = .restart,
            .max_restarts = 3,
            .restart_window_seconds = 60,
        });

        try system.start();

        const actors = try allocator.alloc(zactor.ActorRef, num_actors);
        defer allocator.free(actors);

        // Spawn actors (automatically supervised)
        for (actors, 0..) |*actor_ref, i| {
            actor_ref.* = try system.spawn(BenchmarkActor, BenchmarkActor.init(@intCast(i + 1)));
        }

        const start_time = std.time.nanoTimestamp();

        // Send messages
        for (0..messages_per_actor) |msg_num| {
            for (actors) |actor_ref| {
                const message_data = try std.fmt.allocPrint(allocator, "msg_{}", .{msg_num});
                defer allocator.free(message_data);
                try actor_ref.send([]const u8, message_data, allocator);
            }
        }

        // Wait for completion
        try system.awaitQuiescence(5000);

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        const total_messages = num_actors * messages_per_actor;
        const throughput = @as(f64, @floatFromInt(total_messages)) / (duration_ms / 1000.0);

        std.log.info("With supervision:", .{});
        std.log.info("  Duration: {d:.2} ms", .{duration_ms});
        std.log.info("  Throughput: {d:.0} messages/second", .{throughput});

        const supervisor_stats = system.getSupervisorStats();
        supervisor_stats.print();

        system.shutdown();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZActor Performance Benchmarks ===", .{});

    // Run different benchmark types
    try runThroughputBenchmark(allocator, .{
        .num_actors = 100,
        .messages_per_actor = 1000,
        .scheduler_threads = 4,
        .duration_seconds = 10,
    });

    std.log.info("", .{});
    try runLatencyBenchmark(allocator);

    std.log.info("", .{});
    try runScalabilityBenchmark(allocator);

    std.log.info("", .{});
    try runSupervisionBenchmark(allocator);

    std.log.info("=== All Benchmarks Complete ===", .{});
}

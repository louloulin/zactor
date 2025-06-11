const std = @import("std");
const zactor = @import("src/zactor.zig");

// High-performance counter actor for stress testing
const StressActor = struct {
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

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("StressActor {} starting", .{self.id});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        const count = self.message_count.load(.monotonic);
        std.log.info("StressActor {} stopping with {} messages processed", .{ self.id, count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("StressActor {} restarting due to: {}", .{ self.id, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("StressActor {} restarted", .{self.id});
    }

    pub fn getMessageCount(self: *Self) u64 {
        return self.message_count.load(.monotonic);
    }
};

// Stress test configuration
const StressConfig = struct {
    num_actors: u32 = 10,
    messages_per_actor: u32 = 1000,
    scheduler_threads: u32 = 4,
    test_duration_ms: u64 = 5000,
};

fn runStressTest(allocator: std.mem.Allocator, config: StressConfig) !void {
    std.log.info("=== ZActor Stress Test ===", .{});
    std.log.info("Actors: {}, Messages per actor: {}, Threads: {}", .{ config.num_actors, config.messages_per_actor, config.scheduler_threads });

    // Initialize ZActor
    zactor.init(.{
        .max_actors = config.num_actors * 2,
        .scheduler_threads = config.scheduler_threads,
        .enable_work_stealing = true,
        .mailbox_capacity = 10000,
    });

    // Reset metrics
    zactor.metrics.reset();

    // Create actor system
    var system = try zactor.ActorSystem.init("stress-test-system", allocator);
    defer system.deinit();

    try system.start();
    std.log.info("Actor system started", .{});

    // Spawn stress test actors
    const actors = try allocator.alloc(zactor.ActorRef, config.num_actors);
    defer allocator.free(actors);

    for (actors, 0..) |*actor_ref, i| {
        actor_ref.* = try system.spawn(StressActor, StressActor.init(@intCast(i)));
    }

    std.log.info("Spawned {} actors", .{config.num_actors});

    // Measure message sending throughput
    const start_time = std.time.nanoTimestamp();

    // Send messages to all actors
    for (0..config.messages_per_actor) |msg_num| {
        for (actors) |actor_ref| {
            const message_data = try std.fmt.allocPrint(allocator, "stress_message_{}", .{msg_num});
            defer allocator.free(message_data);

            try actor_ref.send([]const u8, message_data, allocator);
        }

        // Small delay to prevent overwhelming the system
        if (msg_num % 100 == 0) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    const send_end_time = std.time.nanoTimestamp();
    const send_duration_ns = send_end_time - start_time;

    std.log.info("All messages sent in {d:.2} ms", .{@as(f64, @floatFromInt(send_duration_ns)) / 1_000_000.0});

    // Wait for all messages to be processed
    std.log.info("Waiting for message processing...", .{});
    const total_expected_messages = config.num_actors * config.messages_per_actor;

    var wait_time: u64 = 0;
    const max_wait_time = config.test_duration_ms;

    while (wait_time < max_wait_time) {
        const current_received = zactor.metrics.getMessagesReceived();
        if (current_received >= total_expected_messages) {
            break;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
        wait_time += 10;
    }

    const end_time = std.time.nanoTimestamp();
    const total_duration_ns = end_time - start_time;

    // Calculate metrics
    const total_messages = zactor.metrics.getMessagesSent();
    const messages_received = zactor.metrics.getMessagesReceived();
    const duration_seconds = @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0;

    const throughput = @as(f64, @floatFromInt(messages_received)) / duration_seconds;
    const avg_latency_ns = @as(f64, @floatFromInt(total_duration_ns)) / @as(f64, @floatFromInt(messages_received));

    std.log.info("=== Stress Test Results ===", .{});
    std.log.info("Total duration: {d:.3} seconds", .{duration_seconds});
    std.log.info("Messages sent: {}", .{total_messages});
    std.log.info("Messages received: {}", .{messages_received});
    std.log.info("Completion rate: {d:.1}%", .{@as(f64, @floatFromInt(messages_received)) / @as(f64, @floatFromInt(total_expected_messages)) * 100.0});
    std.log.info("Throughput: {d:.0} messages/second", .{throughput});
    std.log.info("Average latency: {d:.2} μs", .{avg_latency_ns / 1000.0});

    // Get system stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    // Performance analysis
    if (throughput > 100_000) {
        std.log.info("✅ EXCELLENT: Throughput > 100K msg/s", .{});
    } else if (throughput > 50_000) {
        std.log.info("✅ GOOD: Throughput > 50K msg/s", .{});
    } else if (throughput > 10_000) {
        std.log.info("⚠️  FAIR: Throughput > 10K msg/s", .{});
    } else {
        std.log.info("❌ POOR: Throughput < 10K msg/s", .{});
    }

    if (avg_latency_ns < 1000) { // < 1μs
        std.log.info("✅ EXCELLENT: Latency < 1μs", .{});
    } else if (avg_latency_ns < 10000) { // < 10μs
        std.log.info("✅ GOOD: Latency < 10μs", .{});
    } else if (avg_latency_ns < 100000) { // < 100μs
        std.log.info("⚠️  FAIR: Latency < 100μs", .{});
    } else {
        std.log.info("❌ POOR: Latency > 100μs", .{});
    }

    system.shutdown();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run different stress test configurations
    const configs = [_]StressConfig{
        .{ .num_actors = 5, .messages_per_actor = 100, .scheduler_threads = 2, .test_duration_ms = 2000 },
        .{ .num_actors = 10, .messages_per_actor = 500, .scheduler_threads = 4, .test_duration_ms = 5000 },
        .{ .num_actors = 20, .messages_per_actor = 1000, .scheduler_threads = 4, .test_duration_ms = 10000 },
    };

    for (configs, 0..) |config, i| {
        std.log.info("\n=== Stress Test Configuration {} ===", .{i + 1});
        try runStressTest(allocator, config);

        // Wait between tests
        std.time.sleep(1000 * std.time.ns_per_ms);
    }

    std.log.info("\n=== All Stress Tests Complete ===", .{});
}

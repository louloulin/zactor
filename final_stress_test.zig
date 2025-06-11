const std = @import("std");
const zactor = @import("src/zactor.zig");

// High-performance counter actor for stress testing
const StressActor = struct {
    const Self = @This();
    
    id: u32,
    message_count: u32,
    
    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .message_count = 0,
        };
    }
    
    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        _ = message;
        self.message_count += 1;
        
        // Log every 100 messages to avoid spam
        if (self.message_count % 100 == 0) {
            std.log.info("Actor {} processed {} messages", .{ self.id, self.message_count });
        }
    }
    
    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("StressActor {} starting", .{self.id});
    }
    
    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("StressActor {} stopping with {} messages processed", .{ self.id, self.message_count });
    }
    
    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("StressActor {} restarting due to: {}", .{ self.id, reason });
    }
    
    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("StressActor {} restarted", .{self.id});
    }
    
    pub fn getMessageCount(self: *Self) u32 {
        return self.message_count;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== ZActor Final Stress Test ===", .{});
    
    // Test configuration
    const num_actors = 5;
    const messages_per_actor = 200;
    const scheduler_threads = 2;
    
    std.log.info("Configuration: {} actors, {} messages each, {} threads", .{ num_actors, messages_per_actor, scheduler_threads });
    
    // Initialize ZActor
    zactor.init(.{
        .max_actors = num_actors * 2,
        .scheduler_threads = scheduler_threads,
        .enable_work_stealing = false, // Disable to avoid concurrency issues
        .mailbox_capacity = 1000,
    });
    
    // Reset metrics
    zactor.metrics.reset();
    
    // Create actor system
    var system = try zactor.ActorSystem.init("stress-test", allocator);
    defer system.deinit();
    
    try system.start();
    std.log.info("Actor system started", .{});
    
    // Wait for system to stabilize
    std.time.sleep(200 * std.time.ns_per_ms);
    
    // Spawn stress test actors
    const actors = try allocator.alloc(zactor.ActorRef, num_actors);
    defer allocator.free(actors);
    
    for (actors, 0..) |*actor_ref, i| {
        actor_ref.* = try system.spawn(StressActor, StressActor.init(@intCast(i)));
        std.time.sleep(50 * std.time.ns_per_ms); // Small delay between spawns
    }
    
    std.log.info("Spawned {} actors", .{num_actors});
    std.time.sleep(500 * std.time.ns_per_ms);
    
    // Measure message sending throughput
    const start_time = std.time.nanoTimestamp();
    
    // Send messages to all actors
    std.log.info("Starting to send messages...", .{});
    for (0..messages_per_actor) |msg_num| {
        for (actors, 0..) |actor_ref, actor_idx| {
            const message_data = try std.fmt.allocPrint(allocator, "msg_{}_{}", .{ actor_idx, msg_num });
            defer allocator.free(message_data);
            
            try actor_ref.send([]const u8, message_data, allocator);
        }
        
        // Small delay every 50 messages to prevent overwhelming
        if (msg_num % 50 == 0) {
            std.time.sleep(10 * std.time.ns_per_ms);
            std.log.info("Sent {} batches of messages", .{msg_num + 1});
        }
    }
    
    const send_end_time = std.time.nanoTimestamp();
    const send_duration_ns = send_end_time - start_time;
    
    std.log.info("All messages sent in {d:.2} ms", .{@as(f64, @floatFromInt(send_duration_ns)) / 1_000_000.0});
    
    // Wait for all messages to be processed
    std.log.info("Waiting for message processing...", .{});
    const total_expected_messages = num_actors * messages_per_actor;
    
    var wait_iterations: u32 = 0;
    const max_wait_iterations = 100; // 10 seconds max
    
    while (wait_iterations < max_wait_iterations) {
        const current_received = zactor.metrics.getMessagesReceived();
        std.log.info("Progress: {}/{} messages processed", .{ current_received, total_expected_messages });
        
        if (current_received >= total_expected_messages) {
            break;
        }
        
        std.time.sleep(100 * std.time.ns_per_ms);
        wait_iterations += 1;
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
    if (throughput > 10_000) {
        std.log.info("✅ EXCELLENT: Throughput > 10K msg/s", .{});
    } else if (throughput > 5_000) {
        std.log.info("✅ GOOD: Throughput > 5K msg/s", .{});
    } else if (throughput > 1_000) {
        std.log.info("⚠️  FAIR: Throughput > 1K msg/s", .{});
    } else {
        std.log.info("❌ POOR: Throughput < 1K msg/s", .{});
    }
    
    if (avg_latency_ns < 10000) { // < 10μs
        std.log.info("✅ EXCELLENT: Latency < 10μs", .{});
    } else if (avg_latency_ns < 100000) { // < 100μs
        std.log.info("✅ GOOD: Latency < 100μs", .{});
    } else if (avg_latency_ns < 1000000) { // < 1ms
        std.log.info("⚠️  FAIR: Latency < 1ms", .{});
    } else {
        std.log.info("❌ POOR: Latency > 1ms", .{});
    }
    
    std.log.info("Shutting down system...", .{});
    system.shutdown();
    
    std.log.info("=== Stress Test Complete ===", .{});
}

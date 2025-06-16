const std = @import("std");
const zactor = @import("zactor");

// Simple benchmark actor that just counts messages
const BenchmarkActor = struct {
    const Self = @This();

    count: u32,
    name: []const u8,

    pub fn init(name: []const u8) Self {
        return Self{
            .count = 0,
            .name = name,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        switch (message.message_type) {
            .user => {
                // Fast path: directly increment without string comparison
                self.count += 1;
            },
            .system => {},
            .control => {},
        }
        _ = context;
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' stopping with count: {}", .{ self.name, self.count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("BenchmarkActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    // Use a simple allocator to avoid memory leak detection issues
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("=== ZActor Performance Benchmark ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("benchmark-system", allocator);
    defer system.deinit();

    // Start the system
    try system.start();

    // Spawn a single actor
    const actor_ref = try system.spawn(BenchmarkActor, BenchmarkActor.init("Benchmark"));

    std.log.info("Spawned BenchmarkActor {}", .{actor_ref.getId()});

    // Measure message sending throughput
    const start_time = std.time.nanoTimestamp();
    const num_messages = 100_000; // 100K messages for high performance testing

    // Send messages with error tracking
    var sent_count: u32 = 0;
    var failed_count: u32 = 0;
    for (0..num_messages) |i| {
        actor_ref.send([]const u8, "increment", allocator) catch |err| {
            failed_count += 1;
            if (failed_count <= 10) { // Only log first 10 failures
                std.log.warn("Failed to send message {}: {}", .{ i, err });
            }
            continue;
        };
        sent_count += 1;
    }
    
    std.log.info("Messages sent successfully: {}, failed: {}", .{ sent_count, failed_count });

    const send_end_time = std.time.nanoTimestamp();
    const send_duration_ns = send_end_time - start_time;

    std.log.info("All {} messages sent in {d:.2} ms", .{ sent_count, @as(f64, @floatFromInt(send_duration_ns)) / 1_000_000.0 });

    // Wait for processing with progress monitoring
    std.log.info("Waiting for message processing...", .{});
    
    // Wait for all messages to be processed with active monitoring
    var wait_count: u32 = 0;
    const max_wait_iterations = 100; // Wait up to 10 seconds
    while (wait_count < max_wait_iterations) {
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms intervals
        
        // Check if mailbox is empty and no more messages to process
        if (actor_ref.mailbox.isEmpty()) {
            std.log.info("Mailbox is empty after {d:.1} seconds", .{@as(f64, @floatFromInt(wait_count)) * 0.1});
            break;
        }
        
        // Log progress every second
        if (wait_count % 10 == 0) {
            const mailbox_size = actor_ref.mailbox.size();
            std.log.info("Progress check: mailbox size = {}, waited {d:.1}s", .{ mailbox_size, @as(f64, @floatFromInt(wait_count)) * 0.1 });
        }
        
        wait_count += 1;
    }
    
    if (wait_count >= max_wait_iterations) {
        std.log.warn("Timeout waiting for message processing after 10 seconds", .{});
    }

    // Calculate throughput
    const total_duration_ns = std.time.nanoTimestamp() - start_time;
    const send_throughput = @as(f64, @floatFromInt(sent_count)) / (@as(f64, @floatFromInt(send_duration_ns)) / 1_000_000_000.0);
    const total_throughput = @as(f64, @floatFromInt(sent_count)) / (@as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0);

    std.log.info("=== Performance Results ===", .{});
    std.log.info("Messages sent: {}", .{sent_count});
    std.log.info("Send throughput: {d:.0} messages/second", .{send_throughput});
    std.log.info("Total throughput: {d:.0} messages/second", .{total_throughput});
    std.log.info("Send latency: {d:.2} μs/message", .{@as(f64, @floatFromInt(send_duration_ns)) / @as(f64, @floatFromInt(num_messages)) / 1000.0});
    std.log.info("Total latency: {d:.2} μs/message", .{@as(f64, @floatFromInt(total_duration_ns)) / @as(f64, @floatFromInt(num_messages)) / 1000.0});

    // Get final statistics
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    std.log.info("Benchmark completed!", .{});

    // Shutdown
    system.shutdown();
    std.log.info("=== Benchmark Complete ===", .{});
}
const std = @import("std");
const zactor = @import("src/zactor.zig");

// Ultra-high-performance test actor
const UltraActor = struct {
    name: []const u8,
    message_count: std.atomic.Value(u64),
    start_time: i128,

    const Self = @This();

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = std.atomic.Value(u64).init(0),
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        
        const count = self.message_count.fetchAdd(1, .monotonic) + 1;
        
        switch (message.message_type) {
            .user => {
                // Minimal processing - just count
                // No parsing, no work simulation
                
                // Report progress every 100k messages
                if (count % 100000 == 0) {
                    const now = std.time.nanoTimestamp();
                    const elapsed_ms = @divTrunc(now - self.start_time, 1000000);
                    const rate = @divTrunc(count * 1000, @as(u64, @intCast(elapsed_ms + 1)));
                    std.log.info("Actor '{s}' processed {}k messages (rate: {} msg/s)", .{ self.name, count / 1000, rate });
                }
            },
            .system => {
                if (message.data.system == .ping) {
                    // Report final stats on ping
                    const now = std.time.nanoTimestamp();
                    const elapsed_ms = @divTrunc(now - self.start_time, 1000000);
                    const rate = @divTrunc(count * 1000, @as(u64, @intCast(elapsed_ms + 1)));
                    std.log.info("🏁 Actor '{s}' final: {} messages in {}ms (rate: {} msg/s)", .{ self.name, count, elapsed_ms, rate });
                }
            },
            .control => {},
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        self.start_time = std.time.nanoTimestamp();
        std.log.info("🚀 UltraActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        const final_count = self.message_count.load(.monotonic);
        std.log.info("🛑 UltraActor '{s}' stopping (processed {} messages)", .{self.name, final_count});
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 UltraActor '{s}' restarting due to: {}", .{self.name, reason});
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 UltraActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === ZActor EXTREME Performance Test ===", .{});

    // Initialize ZActor with maximum performance settings
    zactor.init(.{
        .max_actors = 1000,
        .mailbox_capacity = 8192,
        .scheduler_threads = 8, // Use more threads
        .enable_work_stealing = true,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("extreme-perf-test", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("✅ Actor system started with {} threads", .{8});

    // Wait for system to stabilize
    std.time.sleep(100 * std.time.ns_per_ms);

    // Spawn multiple ultra-performance actors
    const num_actors = 8;
    var actors = std.ArrayList(zactor.ActorRef).init(allocator);
    defer actors.deinit();

    for (0..num_actors) |i| {
        const actor_name = try std.fmt.allocPrint(allocator, "Ultra-{}", .{i});
        defer allocator.free(actor_name);
        
        const actor = try system.spawn(UltraActor, UltraActor.init(actor_name));
        try actors.append(actor);
        std.log.info("✅ Spawned actor: {}", .{actor.getId()});
    }

    // Wait for actors to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Extreme performance test parameters
    const messages_per_actor = 1000000; // 1 million messages per actor
    const total_messages = messages_per_actor * num_actors;
    
    std.log.info("📤 Starting EXTREME test: {} actors × {}M messages = {}M total messages", .{num_actors, messages_per_actor / 1000000, total_messages / 1000000});

    const test_start = std.time.nanoTimestamp();

    // Pre-allocate message content to avoid allocation overhead
    const message_content = "x"; // Minimal message content

    // Send messages to all actors as fast as possible
    for (actors.items) |actor| {
        for (0..messages_per_actor) |_| {
            // Use the optimized string path
            actor.send([]const u8, message_content, allocator) catch |err| {
                if (err == error.MailboxFull) {
                    // Wait a bit and retry
                    std.time.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
        }
    }

    const send_end = std.time.nanoTimestamp();
    const send_time_ms = @divTrunc(send_end - test_start, 1000000);
    const send_rate = @divTrunc(total_messages * 1000, @as(u64, @intCast(send_time_ms + 1)));
    
    std.log.info("📤 Message sending completed in {}ms (rate: {} msg/s)", .{send_time_ms, send_rate});

    // Wait for message processing
    std.log.info("⏳ Waiting for message processing...", .{});
    std.time.sleep(5000 * std.time.ns_per_ms); // Wait longer for processing

    // Send ping to get final stats
    for (actors.items) |actor| {
        try actor.sendSystem(.ping);
    }

    // Wait for final stats
    std.time.sleep(200 * std.time.ns_per_ms);

    // Get system stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    
    const test_end = std.time.nanoTimestamp();
    const total_time_ms = @divTrunc(test_end - test_start, 1000000);
    const overall_rate = @divTrunc(stats.messages_received * 1000, @as(u64, @intCast(total_time_ms + 1)));

    std.log.info("📊 === EXTREME Performance Results ===", .{});
    std.log.info("Total time: {}ms", .{total_time_ms});
    std.log.info("Messages sent: {}", .{stats.messages_sent});
    std.log.info("Messages received: {}", .{stats.messages_received});
    std.log.info("Overall throughput: {} msg/s", .{overall_rate});
    std.log.info("Target: 1,000,000 msg/s - {s}", .{if (overall_rate >= 1000000) "✅ ACHIEVED!" else "❌ Not reached"});
    std.log.info("Actors created: {}", .{stats.actors_created});
    std.log.info("Active workers: {}", .{stats.scheduler_stats.active_workers});

    // Graceful shutdown
    std.log.info("🛑 Shutting down...", .{});
    system.shutdown();

    std.log.info("✅ === EXTREME Performance Test Complete ===", .{});
}

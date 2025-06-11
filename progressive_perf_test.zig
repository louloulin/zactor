const std = @import("std");
const zactor = @import("src/zactor.zig");

// Simple performance test actor
const PerfActor = struct {
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
        const count = self.message_count.fetchAdd(1, .monotonic) + 1;
        
        switch (message.message_type) {
            .user => {
                // Minimal processing for performance
                const user_data = message.data.user;
                if (user_data.is_string) {
                    // Fast path for strings - just access payload directly
                    _ = user_data.payload;
                } else {
                    // Slower path for other types
                    const parsed = user_data.get([]const u8, context.allocator) catch |err| {
                        std.log.warn("Failed to parse message: {}", .{err});
                        return;
                    };
                    defer parsed.deinit();
                    _ = parsed.value;
                }
                
                // Report progress every 10k messages
                if (count % 10000 == 0) {
                    const now = std.time.nanoTimestamp();
                    const elapsed_ms = @divTrunc(now - self.start_time, 1000000);
                    const rate = @divTrunc(count * 1000, @as(u64, @intCast(elapsed_ms + 1)));
                    std.log.info("Actor '{s}' processed {}k messages (rate: {} msg/s)", .{ self.name, count / 1000, rate });
                }
            },
            .system => {
                if (message.data.system == .ping) {
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
        std.log.info("🚀 PerfActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        const final_count = self.message_count.load(.monotonic);
        std.log.info("🛑 PerfActor '{s}' stopping (processed {} messages)", .{self.name, final_count});
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 PerfActor '{s}' restarting due to: {}", .{self.name, reason});
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 PerfActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === Progressive Performance Test ===", .{});

    // Test different configurations progressively
    const test_configs = [_]struct {
        actors: u32,
        messages: u32,
        threads: u32,
        name: []const u8,
    }{
        .{ .actors = 1, .messages = 1000, .threads = 1, .name = "Baseline" },
        .{ .actors = 1, .messages = 10000, .threads = 1, .name = "Single Actor 10k" },
        .{ .actors = 2, .messages = 10000, .threads = 2, .name = "Dual Actor 10k" },
        .{ .actors = 4, .messages = 25000, .threads = 4, .name = "Quad Actor 100k" },
        .{ .actors = 8, .messages = 50000, .threads = 8, .name = "Octa Actor 400k" },
    };

    for (test_configs) |config| {
        std.log.info("\n🧪 Testing: {s} ({} actors, {} msgs each, {} threads)", .{ config.name, config.actors, config.messages, config.threads });
        
        // Initialize ZActor
        zactor.init(.{
            .max_actors = config.actors * 2,
            .mailbox_capacity = 8192,
            .scheduler_threads = config.threads,
            .enable_work_stealing = true,
        });

        // Create actor system
        var system = try zactor.ActorSystem.init("progressive-test", allocator);
        defer system.deinit();

        // Start the system
        try system.start();
        std.time.sleep(50 * std.time.ns_per_ms);

        // Spawn actors
        var actors = std.ArrayList(zactor.ActorRef).init(allocator);
        defer actors.deinit();

        for (0..config.actors) |i| {
            const actor_name = try std.fmt.allocPrint(allocator, "Perf-{}", .{i});
            defer allocator.free(actor_name);
            
            const actor = try system.spawn(PerfActor, PerfActor.init(actor_name));
            try actors.append(actor);
        }

        std.time.sleep(50 * std.time.ns_per_ms);

        const total_messages = config.messages * config.actors;
        std.log.info("📤 Sending {} total messages...", .{total_messages});

        const test_start = std.time.nanoTimestamp();

        // Send messages
        for (actors.items) |actor| {
            for (0..config.messages) |_| {
                actor.send([]const u8, "test", allocator) catch |err| {
                    if (err == error.MailboxFull) {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    std.log.err("Send error: {}", .{err});
                    break;
                };
            }
        }

        const send_end = std.time.nanoTimestamp();
        const send_time_ms = @divTrunc(send_end - test_start, 1000000);
        const send_rate = @divTrunc(total_messages * 1000, @as(u64, @intCast(send_time_ms + 1)));
        
        std.log.info("📤 Sending completed in {}ms (rate: {} msg/s)", .{send_time_ms, send_rate});

        // Wait for processing
        std.time.sleep(1000 * std.time.ns_per_ms);

        // Get final stats
        for (actors.items) |actor| {
            try actor.sendSystem(.ping);
        }
        std.time.sleep(100 * std.time.ns_per_ms);

        const stats = system.getStats();
        defer stats.deinit(allocator);
        
        const test_end = std.time.nanoTimestamp();
        const total_time_ms = @divTrunc(test_end - test_start, 1000000);
        const overall_rate = @divTrunc(stats.messages_received * 1000, @as(u64, @intCast(total_time_ms + 1)));

        std.log.info("📊 {s} Results:", .{config.name});
        std.log.info("  Total time: {}ms", .{total_time_ms});
        std.log.info("  Messages sent: {}", .{stats.messages_sent});
        std.log.info("  Messages received: {}", .{stats.messages_received});
        std.log.info("  Throughput: {} msg/s", .{overall_rate});

        // Shutdown
        system.shutdown();
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    std.log.info("\n✅ === Progressive Performance Test Complete ===", .{});
}

const std = @import("std");
const zactor = @import("src/zactor.zig");

// Ultra-simple test actor that doesn't parse messages
const SimpleActor = struct {
    name: []const u8,
    message_count: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;

        const count = self.message_count.fetchAdd(1, .monotonic) + 1;

        switch (message.message_type) {
            .user => {
                // Don't parse anything - just count
                _ = message.data.user;

                // Report progress every 1000 messages
                if (count % 1000 == 0) {
                    std.log.info("Actor '{s}' processed {} messages", .{ self.name, count });
                }
            },
            .system => {
                if (message.data.system == .ping) {
                    std.log.info("🏁 Actor '{s}' final: {} messages", .{ self.name, count });
                }
            },
            .control => {},
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🚀 SimpleActor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        const final_count = self.message_count.load(.monotonic);
        std.log.info("🛑 SimpleActor '{s}' stopping (processed {} messages)", .{ self.name, final_count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 SimpleActor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 SimpleActor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 === Simple Performance Test ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .mailbox_capacity = 8192,
        .scheduler_threads = 1,
        .enable_work_stealing = false,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("simple-perf-test", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.time.sleep(50 * std.time.ns_per_ms);

    // Spawn one actor
    const actor = try system.spawn(SimpleActor, SimpleActor.init("Simple"));
    std.log.info("✅ Spawned actor: {}", .{actor.getId()});

    std.time.sleep(50 * std.time.ns_per_ms);

    const num_messages = 5000;
    std.log.info("📤 Sending {} messages...", .{num_messages});

    const test_start = std.time.nanoTimestamp();

    // Send messages
    for (0..num_messages) |_| {
        actor.send([]const u8, "test", allocator) catch |err| {
            if (err == error.MailboxFull) {
                std.time.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            std.log.err("Send error: {}", .{err});
            break;
        };
    }

    const send_end = std.time.nanoTimestamp();
    const send_time_ms = @divTrunc(send_end - test_start, 1000000);
    const send_rate = @divTrunc(num_messages * 1000, @as(u64, @intCast(send_time_ms + 1)));

    std.log.info("📤 Sending completed in {}ms (rate: {} msg/s)", .{ send_time_ms, send_rate });

    // Wait for processing
    std.time.sleep(2000 * std.time.ns_per_ms);

    // Get final stats
    try actor.sendSystem(.ping);
    std.time.sleep(100 * std.time.ns_per_ms);

    const stats = system.getStats();
    defer stats.deinit(allocator);

    const test_end = std.time.nanoTimestamp();
    const total_time_ms = @divTrunc(test_end - test_start, 1000000);
    const overall_rate = @divTrunc(stats.messages_received * 1000, @as(u64, @intCast(total_time_ms + 1)));

    std.log.info("📊 Results:", .{});
    std.log.info("  Total time: {}ms", .{total_time_ms});
    std.log.info("  Messages sent: {}", .{stats.messages_sent});
    std.log.info("  Messages received: {}", .{stats.messages_received});
    std.log.info("  Throughput: {} msg/s", .{overall_rate});

    // Shutdown
    system.shutdown();

    std.log.info("✅ === Simple Performance Test Complete ===", .{});
}

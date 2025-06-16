const std = @import("std");
const zactor = @import("src/zactor.zig");

// Debug actor with detailed logging
const DebugActor = struct {
    const Self = @This();

    id: u32,
    count: u32,

    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .count = 0,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        _ = context;
        self.count += 1;
        std.log.info("DebugActor {} received message #{} (type: {})", .{ self.id, self.count, message.message_type });

        switch (message.message_type) {
            .user => {
                std.log.info("  User message payload: {s}", .{message.data.user.payload});
            },
            .system => {
                std.log.info("  System message: {}", .{message.data.system});
            },
            .control => {
                std.log.info("  Control message: {}", .{message.data.control});
            },
        }
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} starting", .{self.id});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} stopping after {} messages", .{ self.id, self.count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("DebugActor {} restarting due to: {}", .{ self.id, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("DebugActor {} restarted", .{self.id});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Debug Message Flow Test ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .scheduler_threads = 1,
        .enable_work_stealing = false,
    });

    // Reset metrics
    zactor.metrics.reset();

    // Create actor system
    var system = try zactor.ActorSystem.init("debug-system", allocator);
    defer system.deinit();

    try system.start();

    // Spawn a debug actor
    const actor_ref = try system.spawn(DebugActor, DebugActor.init(1));

    std.log.info("Actor spawned with ID: {}", .{actor_ref.getId()});
    std.log.info("Actor state: {}", .{actor_ref.getState()});

    // Check initial metrics
    std.log.info("Initial metrics:", .{});
    std.log.info("  Messages sent: {}", .{zactor.metrics.getMessagesSent()});
    std.log.info("  Messages received: {}", .{zactor.metrics.getMessagesReceived()});

    // Send just one test message first
    const message_data = "test_message_0";
    std.log.info("Sending message: {s}", .{message_data});
    try actor_ref.send([]const u8, message_data, allocator);

    // Check metrics after send
    std.log.info("After send: sent={}, received={}", .{ zactor.metrics.getMessagesSent(), zactor.metrics.getMessagesReceived() });

    // Wait a bit more for processing
    std.log.info("Waiting for message processing...", .{});
    std.time.sleep(1000 * std.time.ns_per_ms);

    // Final metrics check
    std.log.info("Final metrics:", .{});
    std.log.info("  Messages sent: {}", .{zactor.metrics.getMessagesSent()});
    std.log.info("  Messages received: {}", .{zactor.metrics.getMessagesReceived()});

    // Get system stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    stats.print();

    std.log.info("=== Debug Test Complete ===", .{});
    system.shutdown();
}

const std = @import("std");
const zactor = @import("src/zactor.zig");

// Test actor that logs every message it receives
const TestActor = struct {
    name: []const u8,
    message_count: u32,

    const Self = @This();

    pub fn init(name: []const u8) Self {
        return Self{
            .name = name,
            .message_count = 0,
        };
    }

    pub fn receive(self: *Self, message: zactor.Message, context: *zactor.ActorContext) !void {
        self.message_count += 1;

        std.log.info("🎯 Actor '{s}' received message #{} (ID: {}, Type: {})", .{ self.name, self.message_count, message.id, message.message_type });

        // Process different message types
        switch (message.message_type) {
            .user => {
                const user_data = message.data.user;
                std.log.info("💬 Actor '{s}' processing user message (payload size: {})", .{ self.name, user_data.payload.len });

                // Try to parse as string
                const parsed = user_data.get([]const u8, context.allocator) catch |err| {
                    std.log.warn("⚠️ Actor '{s}' failed to parse message: {}", .{ self.name, err });
                    return;
                };
                defer parsed.deinit();

                const msg_content = parsed.value;
                if (std.mem.eql(u8, msg_content, "ping")) {
                    std.log.info("📡 Actor '{s}' responding to ping", .{self.name});
                } else if (std.mem.eql(u8, msg_content, "get_count")) {
                    std.log.info("📊 Actor '{s}' message count: {}", .{ self.name, self.message_count });
                } else {
                    std.log.info("💬 Actor '{s}' processed message: {s}", .{ self.name, msg_content });
                }
            },
            .system => {
                std.log.info("🔧 Actor '{s}' processing system message: {}", .{ self.name, message.data.system });
            },
            .control => {
                std.log.info("🎛️ Actor '{s}' processing control message: {}", .{ self.name, message.data.control });
            },
        }

        // Simulate some work
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    pub fn preStart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🚀 Actor '{s}' starting", .{self.name});
    }

    pub fn postStop(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🛑 Actor '{s}' stopping (processed {} messages)", .{ self.name, self.message_count });
    }

    pub fn preRestart(self: *Self, context: *zactor.ActorContext, reason: anyerror) !void {
        _ = context;
        std.log.info("🔄 Actor '{s}' restarting due to: {}", .{ self.name, reason });
    }

    pub fn postRestart(self: *Self, context: *zactor.ActorContext) !void {
        _ = context;
        std.log.info("🔄 Actor '{s}' restarted", .{self.name});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🧪 === Message Processing Test ===", .{});

    // Initialize ZActor
    zactor.init(.{
        .max_actors = 10,
        .mailbox_capacity = 100,
        .scheduler_threads = 2,
        .enable_work_stealing = true,
    });

    // Create actor system
    var system = try zactor.ActorSystem.init("test-system", allocator);
    defer system.deinit();

    // Start the system
    try system.start();
    std.log.info("✅ Actor system started", .{});

    // Give worker threads time to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Spawn test actors
    std.log.info("🎭 Spawning test actors...", .{});
    const actor1 = try system.spawn(TestActor, TestActor.init("TestActor-1"));
    const actor2 = try system.spawn(TestActor, TestActor.init("TestActor-2"));

    std.log.info("✅ Spawned actors: {} and {}", .{ actor1.getId(), actor2.getId() });

    // Wait for actors to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Send test messages
    std.log.info("📤 Sending test messages...", .{});

    try actor1.send([]const u8, "ping", allocator);
    try actor1.send([]const u8, "hello", allocator);
    try actor1.send([]const u8, "get_count", allocator);

    try actor2.send([]const u8, "ping", allocator);
    try actor2.send([]const u8, "world", allocator);

    // Send system messages
    try actor1.sendSystem(.ping);
    try actor2.sendSystem(.ping);

    std.log.info("📤 All messages sent, waiting for processing...", .{});

    // Wait for message processing
    std.time.sleep(500 * std.time.ns_per_ms);

    // Check system stats
    const stats = system.getStats();
    defer stats.deinit(allocator);
    std.log.info("📊 System stats after message processing:", .{});
    stats.print();

    // Send more messages to verify continued processing
    std.log.info("📤 Sending additional messages...", .{});
    try actor1.send([]const u8, "test1", allocator);
    try actor2.send([]const u8, "test2", allocator);
    try actor1.send([]const u8, "get_count", allocator);
    try actor2.send([]const u8, "get_count", allocator);

    // Wait for additional processing
    std.time.sleep(300 * std.time.ns_per_ms);

    // Final stats
    const final_stats = system.getStats();
    defer final_stats.deinit(allocator);
    std.log.info("📊 Final system stats:", .{});
    final_stats.print();

    // Graceful shutdown
    std.log.info("🛑 Shutting down system...", .{});
    system.shutdown();

    std.log.info("✅ === Test Complete ===", .{});
}
